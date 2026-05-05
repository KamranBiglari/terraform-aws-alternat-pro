# Optional VPC endpoints. Default OFF — the failover path needs zero VPC
# endpoints because:
#   * The probe Lambda does pure HTTP curls (no boto3) and lives in the
#     private subnet so its egress test exits via NAT (the very thing being
#     tested). When NAT is down the curl just fails, which is the signal.
#   * Every AWS API call (DescribeRouteTables, DescribeNetworkInterfaces,
#     ReplaceRoute, DynamoDB GetItem/UpdateItem) runs in the SFN service
#     plane, not in the customer VPC.
#   * The lifecycle dispatcher Lambda is a public Lambda (no vpc_config) so
#     its StartExecution call uses public AWS endpoints.
#
# Enable this block ONLY if you want SSM Session Manager into the NAT
# instances for debugging — set var.create_vpc_endpoints = true and pass
# ["ssm", "ssmmessages", "ec2messages"] in
# var.additional_interface_endpoint_services.

locals {
  interface_endpoint_services = var.create_vpc_endpoints ? toset(var.additional_interface_endpoint_services) : toset([])
}

resource "aws_security_group" "vpc_endpoints" {
  count = var.create_vpc_endpoints ? 1 : 0

  name        = "${var.name_prefix}-vpc-endpoints"
  description = "Allows in-VPC components to reach AWS API VPC endpoints (e.g. SSM Session Manager into NAT instances)."
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "vpc_endpoints_https" {
  count = var.create_vpc_endpoints ? 1 : 0

  security_group_id = aws_security_group.vpc_endpoints[0].id
  description       = "HTTPS from the VPC CIDR."
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoint_services

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = distinct(flatten([for m in var.vpc_az_maps : m.private_subnet_ids]))
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-${each.key}"
  })
}
