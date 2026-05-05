data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = "10.44.0.0/16"

  azs             = local.azs
  public_subnets  = [for i, _ in local.azs : cidrsubnet("10.44.0.0/16", 4, i)]
  private_subnets = [for i, _ in local.azs : cidrsubnet("10.44.0.0/16", 4, i + length(local.azs))]

  enable_dns_hostnames = true
  enable_nat_gateway   = false
}

# Attach the VPC to the existing TGW so the fallback route has somewhere to go.
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  subnet_ids         = module.vpc.private_subnets
  transit_gateway_id = var.transit_gateway_id
  vpc_id             = module.vpc.vpc_id

  tags = {
    Name = "${var.name}-tgw-attach"
  }
}

module "alternat" {
  source = "../.."

  name_prefix = var.name
  vpc_id      = module.vpc.vpc_id

  vpc_az_maps = [
    for i, az in local.azs : {
      az                 = az
      public_subnet_id   = module.vpc.public_subnets[i]
      private_subnet_ids = [module.vpc.private_subnets[i]]
      route_table_ids    = [module.vpc.private_route_table_ids[i]]
      fallback = {
        kind               = "transit_gateway"
        transit_gateway_id = var.transit_gateway_id
      }
    }
  ]

  prevent_destroy_eips = false

  # Staged production rollout — deploy the whole stack but DON'T touch
  # route tables yet. Existing TGW egress keeps working until the
  # operator runs the SSM Automation runbook with Action=force-ec2,
  # validates, then flips this to false and re-applies. See README.
  start_in_observation_mode = var.start_in_observation_mode

  tags = {
    Example = "with-transit-gateway-fallback"
  }

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

output "force_fallback_cli_examples" {
  value = module.alternat.force_fallback_cli_examples
}

output "force_ec2_cli_examples" {
  value = module.alternat.force_ec2_cli_examples
}

output "route_control_ssm_cli_examples" {
  value = module.alternat.route_control_ssm_cli_examples
}
