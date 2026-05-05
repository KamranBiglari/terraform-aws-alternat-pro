data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = var.name
  cidr = "10.45.0.0/16"

  azs             = local.azs
  public_subnets  = [for i, _ in local.azs : cidrsubnet("10.45.0.0/16", 4, i)]
  private_subnets = [for i, _ in local.azs : cidrsubnet("10.45.0.0/16", 4, i + length(local.azs))]

  enable_dns_hostnames = true
  enable_nat_gateway   = false
}

module "alternat" {
  source = "../.."

  name_prefix = var.name
  vpc_id      = module.vpc.vpc_id

  vpc_az_maps = [
    {
      # AZ-a — module-managed NAT Gateway fallback, BYO instance EIP
      az                         = local.azs[0]
      public_subnet_id           = module.vpc.public_subnets[0]
      private_subnet_ids         = [module.vpc.private_subnets[0]]
      route_table_ids            = [module.vpc.private_route_table_ids[0]]
      create_nat_gateway         = true
      instance_eip_allocation_id = var.byo_instance_eip_allocation_id
      fallback = {
        kind = "nat_gateway"
      }
    },
    {
      # AZ-b — Transit Gateway fallback
      az                 = local.azs[1]
      public_subnet_id   = module.vpc.public_subnets[1]
      private_subnet_ids = [module.vpc.private_subnets[1]]
      route_table_ids    = [module.vpc.private_route_table_ids[1]]
      fallback = {
        kind               = "transit_gateway"
        transit_gateway_id = var.transit_gateway_id
      }
    },
    {
      # AZ-c — ENI fallback (e.g. a VPN appliance / virtual router ENI)
      az                 = local.azs[2]
      public_subnet_id   = module.vpc.public_subnets[2]
      private_subnet_ids = [module.vpc.private_subnets[2]]
      route_table_ids    = [module.vpc.private_route_table_ids[2]]
      fallback = {
        kind                 = "network_interface"
        network_interface_id = var.fallback_eni_id
      }
    },
  ]

  connectivity_test_check_urls     = ["https://www.cloudflare.com", "https://www.google.com"]
  health_check_schedule_expression = "rate(2 minutes)"
  enable_auto_restore              = false
  cooldown_seconds                 = 600
  prevent_destroy_eips             = true

  # Express SFN — ~80% cheaper for the per-tick health check. Bump
  # log level to ALL because Express has no console execution history;
  # CloudWatch Logs is the only debug surface.
  health_check_sfn_type = "EXPRESS"
  sfn_log_level         = "ALL"

  # SSM-verified auto-restore — when probe says "healthy + on fallback",
  # send an ssm:SendCommand to the live NAT instance to verify
  # iptables/MASQUERADE/EIP before flipping the route back. Force-ec2
  # bypasses this gate (operator override always works).
  enable_nat_restore_ssm_check = true
  ssm_verify_wait_seconds      = 10

  # CloudWatch alarms — publish to caller-supplied SNS topics (e.g. the
  # central ops-alerts topic). Module creates its own topic if alarm_actions
  # is empty.
  create_alarms            = true
  alarm_actions            = var.alarm_actions
  alarm_evaluation_periods = 2 # require two consecutive 5-min windows of failures (suppresses single-tick flakes)
  alarm_threshold          = 1

  # Staged production rollout — when true, route tables are untouched
  # until the operator runs Action=force-ec2 via the SSM Automation
  # runbook. Flip to false and re-apply once validated.
  start_in_observation_mode = var.start_in_observation_mode

  tags = {
    Example = "complete"
  }
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

output "alarm_topic_arn" {
  value = module.alternat.alarm_topic_arn
}

output "alarm_arns" {
  value = module.alternat.alarm_arns
}

output "health_check_state_machine_arn" {
  value = module.alternat.health_check_state_machine_arn
}
