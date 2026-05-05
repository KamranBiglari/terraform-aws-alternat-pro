output "instance_eip_allocation_ids" {
  description = "AZ -> EIP allocation ID claimed by the NAT instance (BYO or module-created)."
  value       = local.eip_allocation_by_az
}

output "nat_gateway_ids" {
  description = "AZ -> NAT Gateway ID for module-managed NGWs."
  value       = { for az, n in aws_nat_gateway.this : az => n.id }
}

output "nat_gateway_eip_allocation_ids" {
  description = "AZ -> EIP allocation ID consumed by module-managed NGWs."
  value       = local.ngw_eip_allocation_by_az
}

output "autoscaling_group_names" {
  description = "AZ -> NAT instance ASG name."
  value       = { for az, a in aws_autoscaling_group.this : az => a.name }
}

output "launch_template_ids" {
  description = "AZ -> launch template ID."
  value       = { for az, lt in aws_launch_template.this : az => lt.id }
}

output "security_group_id" {
  description = "Security group attached to the NAT instances."
  value       = aws_security_group.nat_instance.id
}

output "probe_lambda_arns" {
  description = "AZ -> probe Lambda function ARN."
  value       = { for az, fn in aws_lambda_function.probe : az => fn.arn }
}

output "lifecycle_dispatcher_lambda_arn" {
  description = "ARN of the Lambda that translates ASG lifecycle SNS events into Step Function executions."
  value       = aws_lambda_function.lifecycle_dispatcher.arn
}

output "health_check_state_machine_arn" {
  description = "ARN of the Step Function that runs the periodic health check and handles manual force-fallback / force-ec2 triggers."
  value       = aws_sfn_state_machine.health_check.arn
}

output "lifecycle_state_machine_arn" {
  description = "ARN of the Step Function invoked on ASG instance termination to flip to the configured fallback."
  value       = aws_sfn_state_machine.lifecycle.arn
}

output "lifecycle_topic_arn" {
  description = "SNS topic that receives ASG lifecycle hook notifications."
  value       = aws_sns_topic.lifecycle.arn
}

output "lock_table_name" {
  description = "Name of the DynamoDB table that records the per-AZ transition log."
  value       = aws_dynamodb_table.lock.name
}

output "force_fallback_cli_examples" {
  description = "Per-AZ ready-to-paste AWS CLI commands to force a fallback flip via the health-check SFN."
  value = {
    for az in local.az_keys : az =>
    "aws stepfunctions start-execution --state-machine-arn ${aws_sfn_state_machine.health_check.arn} --input '{\"action\":\"force-fallback\",\"az\":\"${az}\"}'"
  }
}

output "force_ec2_cli_examples" {
  description = "Per-AZ ready-to-paste AWS CLI commands to force the route back to the NAT instance via the health-check SFN."
  value = {
    for az in local.az_keys : az =>
    "aws stepfunctions start-execution --state-machine-arn ${aws_sfn_state_machine.health_check.arn} --input '{\"action\":\"force-ec2\",\"az\":\"${az}\"}'"
  }
}

output "route_control_document_name" {
  description = "Name of the SSM Automation runbook operators can run to force-fallback / force-ec2 / health-check via SSM (instead of raw stepfunctions:StartExecution)."
  value       = aws_ssm_document.route_control.name
}

output "alarm_topic_arn" {
  description = "SNS topic ARN created for the SFN failure alarms when var.create_alarms = true and var.alarm_actions is empty. Subscribe your email / Slack / PagerDuty endpoint to it after apply. Null when alarms are disabled or when caller-supplied alarm_actions are used instead."
  value       = try(aws_sns_topic.alarms[0].arn, null)
}

output "alarm_arns" {
  description = "Map of alarm names to ARNs (empty when var.create_alarms = false)."
  value = var.create_alarms ? {
    health_check = aws_cloudwatch_metric_alarm.health_check_failures[0].arn
    lifecycle    = aws_cloudwatch_metric_alarm.lifecycle_failures[0].arn
  } : {}
}

output "route_control_ssm_cli_examples" {
  description = "Operator-friendly SSM Automation invocation examples — runs from the AWS console form UI too."
  value = merge(
    {
      "force-fallback-all" = "aws ssm start-automation-execution --document-name ${aws_ssm_document.route_control.name} --parameters Action=force-fallback,AZ=all"
      "force-ec2-all"      = "aws ssm start-automation-execution --document-name ${aws_ssm_document.route_control.name} --parameters Action=force-ec2,AZ=all"
      "health-check-all"   = "aws ssm start-automation-execution --document-name ${aws_ssm_document.route_control.name} --parameters Action=health-check,AZ=all"
    },
    {
      for az in local.az_keys :
      "force-fallback-${az}" => "aws ssm start-automation-execution --document-name ${aws_ssm_document.route_control.name} --parameters Action=force-fallback,AZ=${az}"
    },
    {
      for az in local.az_keys :
      "force-ec2-${az}" => "aws ssm start-automation-execution --document-name ${aws_ssm_document.route_control.name} --parameters Action=force-ec2,AZ=${az}"
    }
  )
}
