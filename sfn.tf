locals {
  # AZ records embedded into both Step Functions and the lifecycle dispatcher
  # Lambda. After apply, every fallback id is fully resolved (module-managed
  # NGWs are looked up from aws_nat_gateway).
  sfn_az_records = [
    for m in var.vpc_az_maps : {
      az                 = m.az
      asg_name           = aws_autoscaling_group.this[m.az].name
      route_table_ids    = m.route_table_ids
      test_urls          = var.connectivity_test_check_urls
      fallback_kind      = local.fallback_target_by_az[m.az].kind
      fallback_target_id = local.fallback_target_by_az[m.az].target_id
      probe_arn          = aws_lambda_function.probe[m.az].arn
    }
  ]

  sfn_az_records_by_az = { for r in local.sfn_az_records : r.az => r }
}

resource "aws_cloudwatch_log_group" "sfn_health" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-health-check"
  retention_in_days = var.sfn_log_retention_days
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "sfn_lifecycle" {
  name              = "/aws/vendedlogs/states/${var.name_prefix}-lifecycle"
  retention_in_days = var.sfn_log_retention_days
  tags              = local.common_tags
}

resource "aws_sfn_state_machine" "health_check" {
  name     = "${var.name_prefix}-health-check"
  type     = var.health_check_sfn_type
  role_arn = aws_iam_role.sfn.arn

  definition = templatefile("${path.module}/templates/health-check-sm.json.tftpl", {
    azs                     = local.sfn_az_records
    max_concurrency         = max(length(local.az_keys), 1)
    probe_timeout_seconds   = var.probe_timeout_seconds - 1
    enable_auto_restore     = var.enable_auto_restore
    cooldown_seconds        = var.cooldown_seconds
    lock_table_name         = aws_dynamodb_table.lock.name
    name_prefix             = var.name_prefix
    enable_ssm_verify       = var.enable_nat_restore_ssm_check
    ssm_verify_wait_seconds = var.ssm_verify_wait_seconds
    ssm_document_name       = var.enable_nat_restore_ssm_check ? aws_ssm_document.verify[0].name : ""
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn_health.arn}:*"
    include_execution_data = true
    level                  = var.sfn_log_level
  }

  tracing_configuration {
    enabled = true
  }

  tags = local.common_tags

  # SFN's CreateStateMachine API synchronously validates that the role can
  # access the log destination. Without an explicit dependency on the inline
  # policy, Terraform may create the SFN before the policy is attached and
  # the validation fails with "is not authorized to access the Log Destination".
  depends_on = [aws_iam_role_policy.sfn]
}

resource "aws_sfn_state_machine" "lifecycle" {
  name     = "${var.name_prefix}-lifecycle"
  role_arn = aws_iam_role.sfn.arn

  definition = templatefile("${path.module}/templates/lifecycle-sm.json.tftpl", {
    lock_table_name = aws_dynamodb_table.lock.name
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn_lifecycle.arn}:*"
    include_execution_data = true
    level                  = var.sfn_log_level
  }

  tracing_configuration {
    enabled = true
  }

  tags = local.common_tags

  depends_on = [aws_iam_role_policy.sfn]
}
