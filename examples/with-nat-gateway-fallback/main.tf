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
  cidr = "10.43.0.0/16"

  azs             = local.azs
  public_subnets  = [for i, _ in local.azs : cidrsubnet("10.43.0.0/16", 4, i)]
  private_subnets = [for i, _ in local.azs : cidrsubnet("10.43.0.0/16", 4, i + length(local.azs))]

  enable_dns_hostnames = true
  enable_nat_gateway   = false
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
      create_nat_gateway = true
      fallback = {
        kind = "nat_gateway"
      }
    }
  ]

  prevent_destroy_eips = false

  # Demonstrates the alarms feature — module creates its own SNS topic
  # because alarm_actions is omitted. Subscribe your endpoint after apply:
  #   TOPIC=$(terraform output -raw alarm_topic_arn)
  #   aws sns subscribe --topic-arn $TOPIC --protocol email --notification-endpoint oncall@example.com
  create_alarms = true

  tags = {
    Example = "with-nat-gateway-fallback"
  }
}

output "force_fallback_cli_examples" {
  value = module.alternat.force_fallback_cli_examples
}

output "nat_gateway_ids" {
  value = module.alternat.nat_gateway_ids
}

output "alarm_topic_arn" {
  value = module.alternat.alarm_topic_arn
}

output "alarm_arns" {
  value = module.alternat.alarm_arns
}
