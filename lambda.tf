# =====================================================================
# Probe Lambda (one per AZ — VPC config locks each function to its AZ's
# private subnets so curls actually exit through that AZ's route table)
# =====================================================================

resource "aws_security_group" "probe" {
  name        = "${var.name_prefix}-probe-lambda"
  description = "Egress-only SG for the alternat probe Lambdas."
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "probe_https" {
  security_group_id = aws_security_group.probe.id
  description       = "HTTPS egress for the probe."
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "probe_http" {
  security_group_id = aws_security_group.probe.id
  description       = "HTTP egress for the probe."
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "probe_dns_udp" {
  security_group_id = aws_security_group.probe.id
  description       = "DNS UDP egress for the probe."
  ip_protocol       = "udp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "probe_dns_tcp" {
  security_group_id = aws_security_group.probe.id
  description       = "DNS TCP egress for the probe."
  ip_protocol       = "tcp"
  from_port         = 53
  to_port           = 53
  cidr_ipv4         = "0.0.0.0/0"
}

data "archive_file" "probe" {
  type        = "zip"
  source_dir  = "${path.module}/templates/functions/probe"
  output_path = "${path.module}/.build/probe.zip"
}

resource "aws_cloudwatch_log_group" "probe" {
  for_each = toset(local.az_keys)

  name              = "/aws/lambda/${var.name_prefix}-probe-${each.key}"
  retention_in_days = var.probe_log_retention_days
  tags              = local.common_tags
}

resource "aws_lambda_function" "probe" {
  for_each = toset(local.az_keys)

  function_name                  = "${var.name_prefix}-probe-${each.key}"
  role                           = aws_iam_role.probe_lambda.arn
  handler                        = "app.handler"
  runtime                        = var.probe_runtime
  timeout                        = var.probe_timeout_seconds
  memory_size                    = var.probe_memory_mb
  filename                       = data.archive_file.probe.output_path
  source_code_hash               = data.archive_file.probe.output_base64sha256
  reserved_concurrent_executions = 1

  vpc_config {
    subnet_ids         = local.private_subnet_ids_by_az[each.key]
    security_group_ids = [aws_security_group.probe.id]
  }

  environment {
    variables = {
      AZ = each.key
    }
  }

  depends_on = [aws_cloudwatch_log_group.probe]

  tags = merge(local.common_tags, {
    AZ = each.key
  })
}

# =====================================================================
# Lifecycle dispatcher Lambda (single function, subscribed to SNS)
# =====================================================================

data "archive_file" "lifecycle_dispatcher" {
  type        = "zip"
  source_dir  = "${path.module}/templates/functions/lifecycle_dispatcher"
  output_path = "${path.module}/.build/lifecycle_dispatcher.zip"
}

resource "aws_cloudwatch_log_group" "lifecycle_dispatcher" {
  name              = "/aws/lambda/${var.name_prefix}-lifecycle-dispatcher"
  retention_in_days = var.probe_log_retention_days
  tags              = local.common_tags
}

resource "aws_lambda_function" "lifecycle_dispatcher" {
  function_name    = "${var.name_prefix}-lifecycle-dispatcher"
  role             = aws_iam_role.lifecycle_dispatcher.arn
  handler          = "app.handler"
  runtime          = var.probe_runtime
  timeout          = 30
  memory_size      = 128
  filename         = data.archive_file.lifecycle_dispatcher.output_path
  source_code_hash = data.archive_file.lifecycle_dispatcher.output_base64sha256

  environment {
    variables = {
      LIFECYCLE_STATE_MACHINE_ARN = aws_sfn_state_machine.lifecycle.arn
      OBSERVATION_MODE            = var.start_in_observation_mode ? "true" : "false"
      # Keyed by ASG name (the SNS payload field) so the dispatcher can
      # resolve the per-AZ failover record with no AWS API calls.
      ASG_MAP_JSON = jsonencode({
        for r in local.sfn_az_records : r.asg_name => {
          az                 = r.az
          route_table_ids    = r.route_table_ids
          fallback_kind      = r.fallback_kind
          fallback_target_id = r.fallback_target_id
        }
      })
    }
  }

  depends_on = [aws_cloudwatch_log_group.lifecycle_dispatcher]

  tags = local.common_tags
}

resource "aws_lambda_permission" "lifecycle_dispatcher_sns" {
  statement_id  = "AllowSnsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lifecycle_dispatcher.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.lifecycle.arn
}

resource "aws_sns_topic_subscription" "lifecycle_to_dispatcher" {
  topic_arn = aws_sns_topic.lifecycle.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.lifecycle_dispatcher.arn
}
