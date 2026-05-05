variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "name" {
  type    = string
  default = "alternat-example-tgw"
}

variable "transit_gateway_id" {
  description = "ID of an existing Transit Gateway shared into this account; used as the fallback target."
  type        = string
}

variable "start_in_observation_mode" {
  description = <<-EOT
    Demonstrates the staged rollout pattern. When true, the module deploys
    the whole stack but leaves route tables untouched until the operator
    runs the SSM Automation runbook with Action=force-ec2,AZ=all to
    activate. After validation, set this to false and re-apply to enable
    the EventBridge schedule and lifecycle dispatcher.
  EOT
  type        = bool
  default     = true
}
