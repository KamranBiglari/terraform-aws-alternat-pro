# Transit Gateway fallback example

Two AZs, each with an EC2 NAT instance. When the NAT instance fails the
SFN flips the AZ's default route to a **Transit Gateway** — typically
egressing through a central networking VPC's NAT Gateway in a hub-and-spoke
topology where each spoke account gets its own EC2 NAT for cost, with the
hub's NGW as a safety net.

Also demonstrates the **staged production rollout pattern** via
`start_in_observation_mode = true` (the default for this example): the
module deploys the whole stack but leaves your route tables alone until
you explicitly activate it via the SSM Automation runbook.

## Initial deploy (observation mode)

```sh
terraform init
terraform plan -var "transit_gateway_id=tgw-xxxxxxxx"
terraform apply -var "transit_gateway_id=tgw-xxxxxxxx"
```

After apply: NAT instances are running and configured, EIPs are claimed,
SFN + Lambdas + EventBridge rule are deployed — but your existing
route tables are untouched. Existing TGW egress keeps working.

## Activate

```sh
DOC=$(terraform output -raw route_control_document_name)

# 1. Write routes via the SFN (works even with EB rule disabled)
aws ssm start-automation-execution \
  --document-name $DOC \
  --parameters Action=force-ec2,AZ=all

# 2. Verify workload egress now flows through the NAT instances
#    (e.g. trace a packet from a private-subnet instance)

# 3. Flip out of observation mode and re-apply
terraform apply \
  -var "transit_gateway_id=tgw-xxxxxxxx" \
  -var "start_in_observation_mode=false"
# → EventBridge rule becomes ENABLED (per-minute health check resumes)
# → Lifecycle dispatcher Lambda activates (handles future ASG terminations)
```

## Rollback (during validation)

```sh
aws ssm start-automation-execution \
  --document-name $DOC \
  --parameters Action=force-fallback,AZ=all
# → Routes flip back to the TGW
```

> The TGW must have a route to `0.0.0.0/0` (typically pointing at the
> central NAT Gateway in the networking account) — otherwise the
> "fallback" path also has no internet egress.
