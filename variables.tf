variable "name_prefix" {
  description = "Prefix applied to every resource name created by this module."
  type        = string
  default     = "alternat"
}

variable "vpc_id" {
  description = "ID of the VPC the NAT instances live in."
  type        = string
}

variable "tags" {
  description = "Tags merged into every taggable resource."
  type        = map(string)
  default     = {}
}

variable "vpc_az_maps" {
  description = <<-EOT
    Per-AZ configuration. Each entry declares one AZ that should default-route
    its private subnets through an EC2 NAT instance, and the fallback target
    used when the instance is unhealthy.
  EOT

  type = list(object({
    az                         = string
    public_subnet_id           = string
    private_subnet_ids         = list(string)
    route_table_ids            = list(string)
    create_nat_gateway         = optional(bool, false)
    nat_eip_allocation_id      = optional(string)
    instance_eip_allocation_id = optional(string)
    fallback = object({
      kind                 = string
      nat_gateway_id       = optional(string)
      transit_gateway_id   = optional(string)
      network_interface_id = optional(string)
    })
  }))

  validation {
    condition = alltrue([
      for m in var.vpc_az_maps :
      contains(["nat_gateway", "existing_nat_gateway", "transit_gateway", "network_interface", "none"], m.fallback.kind)
    ])
    error_message = "fallback.kind must be one of: nat_gateway, existing_nat_gateway, transit_gateway, network_interface, none."
  }

  validation {
    condition = alltrue([
      for m in var.vpc_az_maps :
      m.fallback.kind != "existing_nat_gateway" || m.fallback.nat_gateway_id != null
    ])
    error_message = "fallback.kind = \"existing_nat_gateway\" requires fallback.nat_gateway_id."
  }

  validation {
    condition = alltrue([
      for m in var.vpc_az_maps :
      m.fallback.kind != "transit_gateway" || m.fallback.transit_gateway_id != null
    ])
    error_message = "fallback.kind = \"transit_gateway\" requires fallback.transit_gateway_id."
  }

  validation {
    condition = alltrue([
      for m in var.vpc_az_maps :
      m.fallback.kind != "network_interface" || m.fallback.network_interface_id != null
    ])
    error_message = "fallback.kind = \"network_interface\" requires fallback.network_interface_id."
  }

  validation {
    condition = alltrue([
      for m in var.vpc_az_maps :
      m.fallback.kind != "nat_gateway" || m.create_nat_gateway == true
    ])
    error_message = "fallback.kind = \"nat_gateway\" requires create_nat_gateway = true (use \"existing_nat_gateway\" to point at a NGW the module does not manage)."
  }

  validation {
    condition     = length(var.vpc_az_maps) == length(distinct([for m in var.vpc_az_maps : m.az]))
    error_message = "Each AZ may only appear once in vpc_az_maps."
  }
}

variable "nat_instance_type" {
  description = "EC2 instance type for the NAT instance ASG. Default is arm64 (matches the default AMI lookup)."
  type        = string
  default     = "t4g.micro"
}

variable "nat_ami_id" {
  description = "AMI for the NAT instance. When null, the module looks up the latest AL2023 arm64 AMI from SSM."
  type        = string
  default     = null
}

variable "nat_instance_block_devices" {
  description = "Map of block_device_mappings passed verbatim to the launch template (key is logical, value is the block device object)."
  type        = any
  default     = {}
}

variable "enable_detailed_monitoring" {
  description = <<-EOT
    When true (default), the NAT instances publish CloudWatch metrics at
    1-minute granularity (detailed monitoring) instead of the default
    5-minute basic monitoring. This covers the standard EC2 metrics —
    CPUUtilization, NetworkIn/NetworkOut/NetworkPacketsIn/Out, etc. — which
    you can visualize wherever you like. Note that guest memory is not a
    standard EC2 metric and still requires the CloudWatch agent. Detailed
    monitoring incurs a small per-instance CloudWatch cost.
  EOT
  type        = bool
  default     = true
}

variable "max_instance_lifetime" {
  description = "Maximum NAT instance age in seconds before the ASG terminates and replaces it."
  type        = number
  default     = 1209600
}

variable "key_name" {
  description = "Optional SSH key pair name attached to the NAT instances."
  type        = string
  default     = null
}

variable "ingress_security_group_ids" {
  description = "Security group IDs allowed to send traffic into the NAT instance."
  type        = list(string)
  default     = []
}

variable "additional_instance_policies" {
  description = "Extra managed-policy ARNs attached to the NAT instance role."
  type        = list(string)
  default     = []
}

variable "extra_user_data" {
  description = "Bash appended to the NAT instance user-data script (runs after route-replace)."
  type        = string
  default     = ""
}

variable "connectivity_test_check_urls" {
  description = "URLs the probe Lambda curls to validate egress through the NAT instance."
  type        = list(string)
  default = [
    "https://aws.amazon.com",
    "https://www.google.com"
  ]
}

variable "health_check_schedule_expression" {
  description = "EventBridge schedule expression that triggers the health-check state machine."
  type        = string
  default     = "rate(1 minute)"
}

variable "probe_timeout_seconds" {
  description = "Lambda timeout for the probe function."
  type        = number
  default     = 10
}

variable "probe_runtime" {
  description = "Lambda runtime for the probe function."
  type        = string
  default     = "python3.12"
}

variable "probe_memory_mb" {
  description = "Lambda memory in MB for the probe function."
  type        = number
  default     = 128
}

variable "probe_log_retention_days" {
  description = "CloudWatch log retention (days) for the probe Lambda."
  type        = number
  default     = 14
}

variable "enable_auto_restore" {
  description = "When true, the health-check SFN restores the route to the NAT instance once the probe reports healthy again."
  type        = bool
  default     = true
}

variable "start_in_observation_mode" {
  description = <<-EOT
    Deploy the whole stack (ASG, Lambdas, SFN, SSM document) but do NOT
    touch any route table until the operator explicitly activates the
    module. Useful for staged production rollouts.

    When true:
      * The NAT instance user-data runs everything EXCEPT the
        ec2:replaceRoute step, so the instance is fully NAT-capable
        but the route table is unchanged.
      * The EventBridge schedule that drives the periodic health check
        is created in DISABLED state (no auto-flips).
      * The lifecycle dispatcher Lambda short-circuits on SNS events
        (an instance termination won't trigger an unexpected flip to
        fallback while the route is still pre-alternat).

    To activate: run the SSM Automation runbook with
    Action=force-ec2,AZ=all (writes the route via the SFN), validate,
    then set this variable to false and re-apply (enables the schedule
    and dispatcher).

    Force-fallback / force-ec2 / health-check actions invoked through
    the SSM Automation runbook always work regardless of this flag —
    only automatic behaviours are gated.
  EOT
  type        = bool
  default     = false
}

variable "enable_nat_restore_ssm_check" {
  description = <<-EOT
    When true (default), before the SFN auto-restores the route from the
    fallback to the NAT instance, it sends an ssm:SendCommand to the live
    NAT instance to verify it's actually configured correctly (IP forwarding
    on, MASQUERADE rule present, EIP claimed). Only if the verification
    script exits 0 does the SFN flip the route back. Force-ec2 always
    bypasses this gate.

    Requires the NAT instance to have a working SSM agent (the module's
    default AL2023 image + AmazonSSMManagedInstanceCore policy provides
    this; instance reaches SSM via its own EIP, no VPC endpoint needed).
  EOT
  type        = bool
  default     = true
}

variable "ssm_verify_wait_seconds" {
  description = "Seconds the SFN waits between SsmSendCommand and ListCommandInvocations. If the command hasn't completed by then the restore is deferred to the next health-check tick."
  type        = number
  default     = 5
}

variable "cooldown_seconds" {
  description = "Minimum seconds between consecutive route flips for the same AZ."
  type        = number
  default     = 300
}

variable "prevent_destroy_eips" {
  description = "When true the module-created EIPs carry lifecycle.prevent_destroy = true. Disable in non-prod."
  type        = bool
  default     = true
}

variable "lifecycle_topic_kms_key_id" {
  description = "Optional KMS key ID/ARN for the ASG lifecycle SNS topic."
  type        = string
  default     = null
}

variable "create_vpc_endpoints" {
  description = <<-EOT
    Default OFF. The failover path needs zero VPC endpoints because the
    probe Lambda has no AWS API dependencies (pure HTTP test) and every
    AWS call happens in the SFN service plane. Set to true only when you
    want extras like SSM Session Manager into the NAT instance — then
    list the services you need in var.additional_interface_endpoint_services
    (e.g. ["ssm", "ssmmessages", "ec2messages"]).
  EOT
  type        = bool
  default     = false
}

variable "additional_interface_endpoint_services" {
  description = <<-EOT
    Service short-names to create as interface endpoints when
    var.create_vpc_endpoints = true. Common picks: ["ssm", "ssmmessages",
    "ec2messages"] for Session Manager into the NAT instance.
  EOT
  type        = list(string)
  default     = []
}

variable "health_check_sfn_type" {
  description = <<-EOT
    Type of the health-check Step Function.
      * "STANDARD" — exactly-once execution semantics, 90-day execution
        history visible in the SFN console (great for debugging), pricing
        per state transition (~$0.025 / 1000).
      * "EXPRESS"  — at-least-once execution semantics, NO console
        history (must inspect CloudWatch Logs), pricing per request +
        GB-second (~80% cheaper at our ~once-per-minute schedule).

    Switching to EXPRESS is safe for this module because the cooldown
    DDB row already serves as an idempotency guard against duplicate
    executions. The lifecycle SFN is always STANDARD because it fires
    rarely and the console history is more useful than the cost saving.
  EOT
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXPRESS"], var.health_check_sfn_type)
    error_message = "health_check_sfn_type must be either \"STANDARD\" or \"EXPRESS\"."
  }
}

variable "sfn_log_level" {
  description = <<-EOT
    Logging level for both Step Functions.
      * "OFF"   — no execution data sent to CloudWatch Logs.
      * "ERROR" — log only failed states (small log volume; default).
      * "FATAL" — log only fatal failures.
      * "ALL"   — log every state entry/exit/result (verbose; required
                  to debug EXPRESS executions because they have no
                  console history).
  EOT
  type        = string
  default     = "ERROR"

  validation {
    condition     = contains(["OFF", "ERROR", "FATAL", "ALL"], var.sfn_log_level)
    error_message = "sfn_log_level must be one of OFF, ERROR, FATAL, ALL."
  }
}

variable "sfn_log_retention_days" {
  description = "CloudWatch log retention (days) for the Step Function logs."
  type        = number
  default     = 14
}

variable "create_alarms" {
  description = <<-EOT
    When true, deploy CloudWatch alarms for both Step Functions:
      * <prefix>-health-check-failures — health-check SFN had any failed,
        timed-out, or aborted executions in a 5-minute window.
      * <prefix>-lifecycle-failures — lifecycle SFN had any failed,
        timed-out, or aborted executions in a 5-minute window.

    When alarms are enabled and var.alarm_actions is empty, the module
    creates a dedicated SNS topic <prefix>-alarms and wires it as the
    alarm/ok action. Subscribe your email / Slack / PagerDuty endpoint
    to it after apply. Set var.alarm_actions to a list of existing topic
    ARNs to publish to your central alerting topic instead.
  EOT
  type        = bool
  default     = false
}

variable "alarm_actions" {
  description = <<-EOT
    SNS topic ARNs (or other CloudWatch alarm action ARNs) the alarms
    publish to when they enter ALARM state and again on OK. When empty
    and var.create_alarms = true, the module creates its own SNS topic.
  EOT
  type        = list(string)
  default     = []
}

variable "alarm_evaluation_periods" {
  description = "Number of consecutive 5-minute periods of failures required to trigger the alarm."
  type        = number
  default     = 1
}

variable "alarm_threshold" {
  description = "Minimum number of failed executions in a 5-minute period required to trigger the alarm."
  type        = number
  default     = 1
}
