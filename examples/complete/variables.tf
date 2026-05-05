variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "name" {
  type    = string
  default = "alternat-example-complete"
}

variable "transit_gateway_id" {
  description = "Existing TGW used as fallback for one AZ."
  type        = string
}

variable "fallback_eni_id" {
  description = "Existing ENI (e.g. a VPN appliance or virtual router) used as the fallback target for one AZ."
  type        = string
}

variable "byo_instance_eip_allocation_id" {
  description = "Pre-allocated EIP allocation id for AZ-a's NAT instance — demonstrates BYO."
  type        = string
}

variable "alarm_actions" {
  description = "Existing SNS topic ARN(s) to publish SFN failure alarms to (e.g. central ops-alerts topic). When empty, the module creates its own topic."
  type        = list(string)
  default     = []
}

variable "start_in_observation_mode" {
  description = "Deploy in staged-rollout mode (route tables untouched until operator runs Action=force-ec2)."
  type        = bool
  default     = false
}
