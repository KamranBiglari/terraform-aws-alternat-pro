# terraform-aws-alternat-pro

[![ci](https://github.com/KamranBiglari/terraform-aws-alternat-pro/actions/workflows/ci.yml/badge.svg)](https://github.com/KamranBiglari/terraform-aws-alternat-pro/actions/workflows/ci.yml)
[![release](https://github.com/KamranBiglari/terraform-aws-alternat-pro/actions/workflows/release.yml/badge.svg)](https://github.com/KamranBiglari/terraform-aws-alternat-pro/actions/workflows/release.yml)
[![Terraform Registry](https://img.shields.io/badge/Terraform%20Registry-KamranBiglari%2Falternat--pro%2Faws-7B42BC?logo=terraform)](https://registry.terraform.io/modules/KamranBiglari/alternat-pro/aws/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A Terraform module for **self-healing, low-cost EC2 NAT** on AWS, with a
configurable fallback target (NAT Gateway / Transit Gateway / ENI / none),
Step Function-driven failover, SSM-verified auto-restore, CloudWatch
alarms, and a staged-rollout (observation) mode.

Inspired by [chime/terraform-aws-alternat][upstream] but rebuilt with a
service-plane-first architecture: the probe Lambda has zero AWS API
dependencies (pure HTTP curl), so failover keeps working when the NAT
itself is broken — without requiring any paid VPC endpoints.

## Quick start

```hcl
module "alternat" {
  source = "github.com/KamranBiglari/terraform-aws-alternat-pro"

  name_prefix = "myapp"
  vpc_id      = module.vpc.vpc_id

  vpc_az_maps = [
    for i, az in local.azs : {
      az                 = az
      public_subnet_id   = module.vpc.public_subnets[i]
      private_subnet_ids = [module.vpc.private_subnets[i]]
      route_table_ids    = [module.vpc.private_route_table_ids[i]]
      create_nat_gateway = true
      fallback           = { kind = "nat_gateway" }
    }
  ]

  create_alarms             = true
  start_in_observation_mode = true   # safe first deploy
}
```

Pin a version with `?ref=v1.2.3` once you tag releases.

## What it does

Each AZ runs a single EC2 NAT instance in an Auto Scaling Group; a Step
Function probes egress every minute and flips the AZ's default route to a
**configurable fallback target** when the instance is unhealthy. ASG
instance terminations also flip routes — instantly, via SNS → dispatcher
Lambda → Step Function.

## Architecture

```
   EventBridge (rate(1 minute))                ASG terminates instance
              │                                          │
              ▼                                          ▼
   health-check Step Function                      SNS topic
              │                                          │
              ▼                                          ▼
        Map(per AZ)                          lifecycle dispatcher Lambda
              │                              (public Lambda — no VPC, no endpoints)
              ▼                                          │
   ┌──────────────────────────────────────┐              ▼
   │  ALL IN SFN SERVICE PLANE:            │   lifecycle Step Function
   │   dynamodb:GetItem      (lock)        │              │
   │   ec2:DescribeRouteTables             │              ▼
   │   ec2:DescribeNetworkInterfaces       │   ec2:replaceRoute → fallback
   │     (Filter: tag:alternat-az = $.az)  │              │
   └─────────────────┬────────────────────┘              ▼
                     │                          dynamodb:UpdateItem
                     ▼
              probe Lambda            (in VPC, but pure HTTP, NO boto3)
              │  inputs: route_tables, live_eni, lock, expected_fallback
              │  does:   curls test URLs + classifies each RT
              │  returns: { healthy, current_target, new_cooldown_until }
              ▼
        Choice on { action, healthy, current_target, cooldown_active }
                     │
           ┌─────────┴─────────┐
           ▼                   ▼
   ec2:replaceRoute    ec2:replaceRoute
   → NAT instance ENI  → fallback target
           │                   │
           └─────────┬─────────┘
                     ▼
            dynamodb:UpdateItem
            (record transition + cooldown)
```

## Fallback kinds

| `fallback.kind`         | requires                              | module creates? | route written |
| ----------------------- | ------------------------------------- | --------------- | ------------- |
| `nat_gateway`           | `create_nat_gateway = true`           | NAT Gateway     | `NatGatewayId` |
| `existing_nat_gateway`  | `fallback.nat_gateway_id`             | no              | `NatGatewayId` |
| `transit_gateway`       | `fallback.transit_gateway_id`         | no              | `TransitGatewayId` |
| `network_interface`     | `fallback.network_interface_id`       | no              | `NetworkInterfaceId` |
| `none`                  | —                                     | no              | (no swap; egress stays broken until ASG replaces the instance) |

## Manual triggers

Two ways to manually trigger a route flip — both end up calling the same
health-check Step Function. Pick whichever your team prefers.

### Option A — SSM Automation runbook (operator-friendly)

The module ships an SSM Automation document named
`${name_prefix}-route-control` that wraps the SFN call. You can run it
from the AWS console (Systems Manager → Automation → Execute automation
→ pick the document → fill the form) or from the CLI:

```sh
DOC=$(terraform output -raw route_control_document_name)

# Force every AZ to its fallback
aws ssm start-automation-execution \
  --document-name $DOC \
  --parameters Action=force-fallback,AZ=all

# Force one AZ back to its NAT instance
aws ssm start-automation-execution \
  --document-name $DOC \
  --parameters Action=force-ec2,AZ=eu-west-1a

# Ad-hoc health check (same logic the EventBridge tick runs every minute)
aws ssm start-automation-execution \
  --document-name $DOC \
  --parameters Action=health-check,AZ=all
```

`Action` is constrained to `force-fallback | force-ec2 | health-check`
(SSM rejects other values at submission). The runbook output is the
SFN execution ARN — follow it in the Step Function console to see the
per-AZ Map results. The whole call is one control-plane operation; no
NAT instance needs to be reachable for it to work.

The module exports a ready-to-paste map of every command via the
`route_control_ssm_cli_examples` output.

### Option B — Direct `aws stepfunctions start-execution` (no SSM dependency)

```sh
HC=$(terraform output -raw health_check_state_machine_arn)

aws stepfunctions start-execution --state-machine-arn $HC \
  --input '{"action":"force-fallback","az":"all"}'

aws stepfunctions start-execution --state-machine-arn $HC \
  --input '{"action":"force-ec2","az":"eu-west-1a"}'

aws stepfunctions start-execution --state-machine-arn $HC \
  --input '{"action":"health-check","az":"all"}'
```

`force_fallback_cli_examples` and `force_ec2_cli_examples` outputs
contain ready-to-paste versions per AZ.

### Action semantics (both options)

| `Action` | What it does | Bypasses |
| --- | --- | --- |
| `force-fallback` | Flip route to the configured fallback (NGW/TGW/ENI) | cooldown |
| `force-ec2` | Flip route back to the NAT instance ENI | cooldown **and** SSM verify |
| `health-check` | Run the same logic as the EventBridge tick | nothing |

## Alarms

Set `var.create_alarms = true` to deploy a CloudWatch alarm per Step
Function. Each alarm fires when the sum of `ExecutionsFailed +
ExecutionsTimedOut + ExecutionsAborted` exceeds the threshold (default
≥ 1) over a 5-minute window — covering every "execution didn't
succeed" mode in a single signal.

| Alarm | Source SFN |
| --- | --- |
| `${name_prefix}-health-check-failures` | health-check |
| `${name_prefix}-lifecycle-failures` | lifecycle |

### Where notifications go

**A) Module creates an SNS topic** (default when `alarm_actions = []`):

```hcl
module "alternat" {
  ...
  create_alarms = true
}
```

After apply, subscribe your endpoint:

```sh
TOPIC=$(terraform output -raw alarm_topic_arn)
aws sns subscribe --topic-arn $TOPIC --protocol email --notification-endpoint oncall@example.com
# (confirm the email subscription in your inbox)
```

**B) Use your existing topic(s)** — common in central-alerting setups:

```hcl
module "alternat" {
  ...
  create_alarms = true
  alarm_actions = [
    "arn:aws:sns:eu-west-1:123456789012:ops-alerts",
    "arn:aws:sns:eu-west-1:123456789012:pagerduty-bridge",
  ]
}
```

Both `alarm_actions` and `ok_actions` are wired to the same list, so
you get both fire-and-clear notifications.

### Tuning

* `var.alarm_threshold` (default `1`) — how many failures in a 5-min
  window trigger the alarm.
* `var.alarm_evaluation_periods` (default `1`) — how many consecutive
  5-min windows must breach. Set higher to suppress flaky single-tick
  alerts.

## Staged production rollout (observation mode)

`var.start_in_observation_mode = true` deploys the whole stack but
leaves your route tables untouched until you explicitly activate it.
Useful for production rollouts where you want to validate the
infrastructure before flipping default-route traffic onto the new
NAT instances.

When `start_in_observation_mode = true`:

| Component | Behaviour |
| --- | --- |
| NAT instance user-data | Runs everything (IP forwarding, iptables, EIP claim, ENI tagging) **except** the `ec2:replaceRoute` step. Instance is fully NAT-capable but the route table is unchanged. |
| EventBridge schedule | Created in `DISABLED` state. The periodic health-check tick does not fire — no auto-flips. |
| Lifecycle dispatcher Lambda | Logs the SNS event and exits without invoking the lifecycle SFN. An ASG instance termination won't unexpectedly flip the route to fallback. |
| SSM Automation runbook + manual `force-*` SFN triggers | Always work — operator can write the route at the moment of their choosing. |

### Activation workflow

```sh
DOC=$(terraform output -raw route_control_document_name)

# 1. While still in observation mode: write the route via SSM Automation
aws ssm start-automation-execution \
  --document-name $DOC \
  --parameters Action=force-ec2,AZ=all
# Manual StartExecution works even with the EventBridge rule disabled.
# The SFN finds the live NAT instance ENI by its alternat-az tag and
# calls ec2:replaceRoute.

# 2. Verify routing — workloads' egress now goes through the NAT instances.

# 3. Edit tfvars: start_in_observation_mode = false
# 4. terraform apply
#    → EventBridge rule becomes ENABLED (per-minute health check resumes)
#    → Dispatcher Lambda OBSERVATION_MODE flips to "false" (lifecycle path resumes)
```

To **roll back** during validation, run the runbook with
`Action=force-fallback,AZ=all` — flips routes back to the configured
fallback target.

## Express vs Standard for the health-check SFN

`var.health_check_sfn_type` (default `"STANDARD"`) toggles the type of
the health-check state machine:

| | `STANDARD` | `EXPRESS` |
| --- | --- | --- |
| Cost (rate(1 min) × 1 AZ × 30 d) | ~$13/mo | **~$3/mo** |
| Execution history in SFN console | 90 days, full visual graph | none — must read CloudWatch Logs |
| Execution semantics | exactly-once | at-least-once |
| Max duration per execution | 1 year | 5 minutes (we use ~10–20 s) |
| Startup latency | seconds | ~50 ms |

Switching to `EXPRESS` is safe in this module because the per-AZ
cooldown row in DynamoDB already serves as an idempotency guard
(at-least-once duplicates short-circuit at `InCooldown`). When you
choose `EXPRESS`, also bump `var.sfn_log_level` to `"ALL"` so log
analysis can replace the missing console history — otherwise
debugging is painful.

The lifecycle SFN is always `STANDARD` (it fires rarely and the
console history is more useful than the cost saving).

`var.sfn_log_level` accepts `OFF` / `ERROR` (default) / `FATAL` /
`ALL` — applies to both state machines.

## SSM-verified auto-restore

`var.enable_nat_restore_ssm_check = true` (default) inserts a verification
gate between "probe says healthy + currently on fallback" and the actual
route flip back to the NAT instance. The SFN sends an
`ssm:SendCommand` to the live NAT instance running a script that checks:

- `net.ipv4.ip_forward = 1`
- iptables NAT MASQUERADE rule is present
- the instance has claimed a public IPv4 (EIP)
- an outbound HTTPS curl through itself succeeds

It then waits `var.ssm_verify_wait_seconds` (default 5s) and reads the
command status. Only on `Status = Success` does it call `ec2:replaceRoute`
to flip the AZ back to the EC2 NAT. Anything else (timeout, failed,
in-progress, agent unreachable) → defer to the next health-check tick.

`force-ec2` bypasses this gate so an operator can always override.

Set `var.enable_nat_restore_ssm_check = false` to skip the verify
step and go straight from "probe healthy" to route flip — saves the
~5s wait per restore but you trust the HTTP probe alone.

## How the system knows what's running

The Step Function is the orchestrator; the probe Lambda is the network
sensor. Per AZ each tick the SFN does, in the service plane:

1. `dynamodb:GetItem` → reads the per-AZ lock
   (`cooldown_until`, `last_target`, `last_changed_at`).
2. `ec2:DescribeRouteTables` → fetches the current default-route target
   for every managed route table.
3. `ec2:DescribeNetworkInterfaces` with
   `Filter: tag:alternat-az={az} + tag:alternat-name-prefix={prefix} + status=in-use`
   → finds the live NAT instance's primary ENI.
4. `lambda:Invoke` the probe with all that data plus the configured
   fallback kind+id.

The probe then curls the test URLs (which exits via NAT — that's the
sensor) and classifies each route table as `ec2` / `fallback` / `stale`
/ `unknown` by comparing each RT's default-route target against
(a) the live ENI and (b) the configured fallback. Returns a consensus
`current_target` plus the recommended `new_cooldown_until`.

The Step Function branches on that consensus value:

| `healthy` | `current_target` | action  | result        |
| --------- | ---------------- | ------- | ------------- |
| false     | any              | health  | flip to fallback |
| true      | `ec2`            | health  | no-op         |
| true      | `fallback`       | health  | restore to EC2 (if `enable_auto_restore = true`, gated by SSM verify) |
| true      | `stale` / `mixed`| health  | restore to EC2 (if `enable_auto_restore = true`, gated by SSM verify) |
| —         | —                | force-fallback | flip to fallback |
| —         | —                | force-ec2      | flip to live EC2 ENI (bypasses SSM verify) |
| any       | any              | (cooldown_active) | skip   |

## Reliability — what happens when NAT is down

The architecture deliberately removes the bootstrap problem upstream
suffers (probe Lambda can't reach AWS APIs when the NAT it's testing is
down):

1. **Zero VPC endpoints required.** The probe Lambda has **no boto3
   calls at all** — it is a pure HTTP curl. Every piece of AWS state it
   needs (route tables, live NAT ENI, lock state) is fetched by the Step
   Function in the **service plane** and passed to the probe as input.
   When NAT is broken, the probe's curl simply fails — that's the
   signal — and the SFN handles the route flip from the service plane,
   where AWS APIs are always reachable. The lifecycle dispatcher Lambda
   is also a public Lambda (no `vpc_config`) so its `StartExecution`
   call uses public AWS endpoints. (Compare: upstream
   `chime/terraform-aws-alternat` creates a paid EC2 interface endpoint
   per AZ because their probe Lambda calls `ec2:DescribeRouteTables` /
   `ec2:ReplaceRoute` from inside the VPC.)
2. **Live ENI lookup via tag.** User-data tags the NAT instance's
   primary ENI with `alternat-az={az}` + `alternat-name-prefix={prefix}`.
   The SFN then finds the live ENI with one
   `ec2:DescribeNetworkInterfaces` Filter call — no
   DescribeAutoScalingGroups + DescribeInstances chain.
3. **Retry + Catch on every `ec2:replaceRoute`** in both Step Functions
   (3 attempts, exponential backoff). Transient throttling won't kill
   the execution; failures fall through to a `RouteWriteFailed` state
   that records the error so it shows up in the SFN execution history.
4. **User-data hardening** — every AWS CLI call in the NAT instance
   bootstrap (modify-instance-attribute, associate-address,
   replace-route, create-route, create-tags) is wrapped in a 5-attempt
   retry with exponential backoff.
5. **Probe Lambda `reserved_concurrent_executions = 1`** per AZ — a
   slow probe can't pile up overlapping invocations under the
   `rate(1 minute)` schedule.
6. **Probe ground truth.** The probe receives the route-table
   inventory + the live ENI ID + the configured fallback kind+id and
   classifies each route table individually as
   `ec2` / `fallback` / `stale` / `unknown`. The SFN decides from the
   consensus value, not from heuristics.

`var.create_vpc_endpoints` defaults to **false** — opt in only when you
want extras like SSM Session Manager (`["ssm", "ssmmessages",
"ec2messages"]` in `var.additional_interface_endpoint_services`).

## EIPs

`prevent_destroy_eips = true` (default) protects module-managed EIPs from
being destroyed. Each AZ can also bring its own EIP allocation IDs:

```hcl
{
  az                         = "eu-west-1a"
  instance_eip_allocation_id = "eipalloc-xxxxxxxx"  # for the NAT instance
  nat_eip_allocation_id      = "eipalloc-yyyyyyyy"  # for the module NGW (optional)
  ...
}
```

When omitted, the module creates the EIP and reuses it across applies.

## Examples

- [`examples/simple`](examples/simple) — single AZ, no fallback
- [`examples/with-nat-gateway-fallback`](examples/with-nat-gateway-fallback) — module-managed NGW per AZ, demonstrates `create_alarms`
- [`examples/with-transit-gateway-fallback`](examples/with-transit-gateway-fallback) — TGW fallback, demonstrates the staged rollout (observation mode) workflow
- [`examples/complete`](examples/complete) — three AZs with mixed fallback kinds, BYO EIPs, Express SFN, alarms wired to external SNS, observation mode toggle

## Caveats

- **Caller-managed default route**: alternat owns `0.0.0.0/0` for the
  route tables listed in `vpc_az_maps[].route_table_ids`. Don't define
  another `aws_route` with `destination_cidr_block = "0.0.0.0/0"` against
  any of them.
- **Cross-AZ NGW fallback** incurs cross-AZ data charges. Prefer one
  module-managed NGW per AZ when using `nat_gateway` fallback.
- **AL2023 arm64 default**: the default `nat_instance_type = t4g.micro`
  expects an arm64 AMI. Set `nat_ami_id` if you switch to an x86 type.
- **`prevent_destroy` toggle**: implemented as two parallel resources
  (`*_protected` / `*_unprotected`) selected by `count`. Switching the
  flag in non-prod requires `terraform state mv`.
- **Cooldown** is observed by the periodic check and recorded after every
  flip; `force-fallback` and `force-ec2` deliberately bypass it so
  operators can always override.

## Publishing & releases

This repo ships with two GitHub Actions workflows:

- **[`ci.yml`](.github/workflows/ci.yml)** runs on every push and PR.
  Fails the build on any of: `terraform fmt -check`, `terraform validate`
  (root + each example via a matrix job), or `tflint --recursive`.
- **[`release.yml`](.github/workflows/release.yml)** runs on every push to
  `main`. Uses [`googleapis/release-please-action`][release-please] to
  open / update a "Release PR" that bumps the version in
  [`.github/.release-please-manifest.json`](.github/.release-please-manifest.json)
  and refreshes `CHANGELOG.md`. When a maintainer merges that PR,
  release-please tags the merge commit `vX.Y.Z` and creates a GitHub
  Release with the changelog.

### Commit messages drive the version

Conventional-commits subset (the prefix on the **first line** of the commit
message decides the bump):

| Prefix | Bump |
| --- | --- |
| `feat: ...`             | minor (`0.1.0` → `0.2.0`) |
| `fix: ...`              | patch (`0.1.0` → `0.1.1`) |
| `feat!: ...` / footer `BREAKING CHANGE:` | major (`0.1.0` → `1.0.0`) |
| `chore:` / `docs:` / `refactor:` / `test:` / `ci:` / `build:` / `style:` | no bump (changelog-only) |

(While the version is `0.x.y`, breaking changes only bump the minor.
That switches to major bumps once `1.0.0` is reached — controlled by
`bump-minor-pre-major` in the release-please config.)

### Terraform Registry

The public Terraform Registry watches the GitHub repo and ingests every
new `vX.Y.Z` tag automatically — there is no separate "publish" step.
**One-time setup:**

1. Sign in at <https://registry.terraform.io> with the `KamranBiglari`
   GitHub account.
2. *Publish module* → select `terraform-aws-alternat-pro`.
3. The repo name `terraform-<provider>-<name>` is required by the
   registry — this repo is named `terraform-aws-alternat-pro` so it
   maps to provider `aws`, name `alternat-pro`.

After that, every release-please tag becomes a registry version, and
consumers can pin via:

```hcl
module "alternat" {
  source  = "KamranBiglari/alternat-pro/aws"
  version = "~> 0.1"
  ...
}
```

(Until the registry is connected, `source = "github.com/KamranBiglari/terraform-aws-alternat-pro?ref=vX.Y.Z"`
also works.)

### Local checks before pushing

```sh
terraform fmt -recursive
terraform init -backend=false && terraform validate
for ex in simple with-nat-gateway-fallback with-transit-gateway-fallback complete; do
  ( cd examples/$ex && terraform init -backend=false && terraform validate )
done
tflint --init && tflint --recursive
```

[release-please]: https://github.com/googleapis/release-please-action

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

Architecture inspired by [chime/terraform-aws-alternat][upstream], rebuilt
with a service-plane-first design that eliminates the VPC endpoint
requirement and adds Step Function orchestration, configurable fallback
kinds, alarms, and observation mode.

[upstream]: https://github.com/chime/terraform-aws-alternat
