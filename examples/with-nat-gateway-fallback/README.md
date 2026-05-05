# NAT Gateway fallback example

Two AZs, each running an EC2 NAT instance with a per-AZ **module-managed
NAT Gateway** as the fallback. When a NAT instance is unhealthy the
health-check Step Function flips that AZ's default route to the AZ's NAT
Gateway. When the new instance comes back healthy, the route is auto-
restored (after the SSM verify gate confirms the instance is configured
correctly).

Also demonstrates the **alarms feature** — `create_alarms = true` makes
the module create its own SNS topic for SFN failure notifications.

```sh
terraform init
terraform plan
terraform apply

# Subscribe your endpoint to the auto-created alarms topic:
TOPIC=$(terraform output -raw alarm_topic_arn)
aws sns subscribe --topic-arn $TOPIC \
  --protocol email --notification-endpoint oncall@example.com
# (confirm via the email)
```

> One NGW per AZ avoids cross-AZ data charges during fallback. Set
> `create_nat_gateway = false` on AZs that should share another AZ's NGW
> via `fallback.kind = "existing_nat_gateway"` if you accept that cost.
