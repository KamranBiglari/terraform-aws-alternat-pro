resource "aws_cloudwatch_event_rule" "health_check" {
  name                = "${var.name_prefix}-health-check"
  description         = "Periodic NAT health check for the alternat module."
  schedule_expression = var.health_check_schedule_expression
  state               = var.start_in_observation_mode ? "DISABLED" : "ENABLED"
  tags                = local.common_tags
}

resource "aws_cloudwatch_event_target" "health_check" {
  rule     = aws_cloudwatch_event_rule.health_check.name
  arn      = aws_sfn_state_machine.health_check.arn
  role_arn = aws_iam_role.eventbridge.arn

  input = jsonencode({
    action = "health-check"
    az     = "all"
  })
}
