# Complete example

Three AZs with **mixed fallback kinds** plus every advanced feature the
module supports. Suitable as a reference for production deployments.

## Per-AZ fallback configuration

| AZ  | Fallback kind        | Notes                           |
| --- | -------------------- | ------------------------------- |
| a   | `nat_gateway`        | Module creates the NGW; BYO EIP for the NAT instance |
| b   | `transit_gateway`    | Egress via central TGW          |
| c   | `network_interface`  | Falls back to an existing VPN appliance ENI |

## Features enabled

| Setting | Value | Effect |
| --- | --- | --- |
| `enable_auto_restore` | `false` | Once flipped to fallback, stays there until operator runs `force-ec2` |
| `cooldown_seconds` | `600` | At least 10 minutes between automatic flips per AZ |
| `health_check_schedule_expression` | `rate(2 minutes)` | Cheaper than 1-minute |
| `prevent_destroy_eips` | `true` | Production setting |
| `health_check_sfn_type` | `EXPRESS` | ~80% cheaper than Standard |
| `sfn_log_level` | `ALL` | Required for Express because there's no console execution history |
| `enable_nat_restore_ssm_check` | `true` | SSM-verified auto-restore (script verifies iptables/MASQUERADE/EIP before route flip) |
| `ssm_verify_wait_seconds` | `10` | More forgiving than default 5 — fewer "deferred to next tick" cycles |
| `create_alarms` | `true` | CloudWatch alarms on failed/timed-out/aborted SFN executions |
| `alarm_actions` | passed in via var | Publishes to your central ops-alerts SNS topic(s) |
| `alarm_evaluation_periods` | `2` | Two consecutive 5-min windows of failures before firing — suppresses single-tick flakes |
| `start_in_observation_mode` | controlled by var | Set `true` for first deploy, then `false` after activation |

## Deploy

```sh
terraform init

# First deploy — observation mode (route tables untouched)
terraform apply \
  -var "transit_gateway_id=tgw-xxxxxxxx" \
  -var "fallback_eni_id=eni-yyyyyyyy" \
  -var "byo_instance_eip_allocation_id=eipalloc-zzzzzzzz" \
  -var 'alarm_actions=["arn:aws:sns:eu-west-1:123456789012:ops-alerts"]' \
  -var "start_in_observation_mode=true"
```

## Activate

```sh
DOC=$(terraform output -raw route_control_document_name)

# 1. Write routes via SSM Automation
aws ssm start-automation-execution \
  --document-name $DOC \
  --parameters Action=force-ec2,AZ=all

# 2. Verify egress

# 3. Re-apply with observation_mode=false
terraform apply \
  -var "transit_gateway_id=tgw-xxxxxxxx" \
  -var "fallback_eni_id=eni-yyyyyyyy" \
  -var "byo_instance_eip_allocation_id=eipalloc-zzzzzzzz" \
  -var 'alarm_actions=["arn:aws:sns:eu-west-1:123456789012:ops-alerts"]' \
  -var "start_in_observation_mode=false"
```
