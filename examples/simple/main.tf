data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = "10.42.0.0/16"

  azs             = [data.aws_availability_zones.available.names[0]]
  public_subnets  = ["10.42.0.0/20"]
  private_subnets = ["10.42.16.0/20"]

  enable_dns_hostnames = true
  enable_nat_gateway   = false
}

module "alternat" {
  source = "../.."

  name_prefix = var.name
  vpc_id      = module.vpc.vpc_id

  vpc_az_maps = [
    {
      az                 = data.aws_availability_zones.available.names[0]
      public_subnet_id   = module.vpc.public_subnets[0]
      private_subnet_ids = [module.vpc.private_subnets[0]]
      route_table_ids    = module.vpc.private_route_table_ids
      fallback = {
        kind = "none"
      }
    }
  ]

  prevent_destroy_eips = false

  tags = {
    Example = "simple"
  }
}

output "force_fallback_cli_examples" {
  value = module.alternat.force_fallback_cli_examples
}

output "health_check_state_machine_arn" {
  value = module.alternat.health_check_state_machine_arn
}

output "route_control_document_name" {
  value = module.alternat.route_control_document_name
}
