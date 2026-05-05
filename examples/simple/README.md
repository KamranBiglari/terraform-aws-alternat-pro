# Simple example

Single AZ, single NAT instance, **no fallback**. The cheapest possible
configuration — useful for development environments where you want NAT
egress without paying for a NAT Gateway and an unhealthy instance simply
breaks egress until the ASG replaces it.

```sh
terraform init
terraform plan
```

## Manually trigger from SSM Automation

The module exposes a runbook for operator-driven failover/restore:

```sh
DOC=$(terraform output -raw route_control_document_name)

aws ssm start-automation-execution \
  --document-name $DOC \
  --parameters Action=health-check,AZ=all
```

(`force-fallback` would be a no-op here because `fallback.kind = "none"`.)
