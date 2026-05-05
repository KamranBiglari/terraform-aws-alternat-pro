# CloudWatch alarms for the two Step Functions. Gated on var.create_alarms.
# Each alarm sums ExecutionsFailed + ExecutionsTimedOut + ExecutionsAborted
# (anything-not-Succeeded) over the evaluation window so a single alarm
# captures every failure mode for that state machine.

locals {
  # When alarms are enabled and the caller didn't supply action ARNs,
  # publish to a module-managed SNS topic the operator can subscribe to.
  alarm_topic_create      = var.create_alarms && length(var.alarm_actions) == 0
  effective_alarm_actions = var.create_alarms ? (length(var.alarm_actions) > 0 ? var.alarm_actions : [aws_sns_topic.alarms[0].arn]) : []
}

resource "aws_sns_topic" "alarms" {
  count = local.alarm_topic_create ? 1 : 0

  name              = "${var.name_prefix}-alarms"
  kms_master_key_id = var.lifecycle_topic_kms_key_id
  tags              = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "health_check_failures" {
  count = var.create_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-health-check-failures"
  alarm_description   = "alternat health-check Step Function had failed/timed-out/aborted executions. Investigate via the SFN console or CloudWatch Logs (vendedlogs/states/${var.name_prefix}-health-check)."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.alarm_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "anyFailure"
    label       = "AnyFailure"
    return_data = true
    expression  = "failed + timedOut + aborted"
  }
  metric_query {
    id = "failed"
    metric {
      namespace   = "AWS/States"
      metric_name = "ExecutionsFailed"
      period      = 300
      stat        = "Sum"
      dimensions = {
        StateMachineArn = aws_sfn_state_machine.health_check.arn
      }
    }
  }
  metric_query {
    id = "timedOut"
    metric {
      namespace   = "AWS/States"
      metric_name = "ExecutionsTimedOut"
      period      = 300
      stat        = "Sum"
      dimensions = {
        StateMachineArn = aws_sfn_state_machine.health_check.arn
      }
    }
  }
  metric_query {
    id = "aborted"
    metric {
      namespace   = "AWS/States"
      metric_name = "ExecutionsAborted"
      period      = 300
      stat        = "Sum"
      dimensions = {
        StateMachineArn = aws_sfn_state_machine.health_check.arn
      }
    }
  }

  alarm_actions = local.effective_alarm_actions
  ok_actions    = local.effective_alarm_actions

  tags = local.common_tags
}

resource "aws_cloudwatch_metric_alarm" "lifecycle_failures" {
  count = var.create_alarms ? 1 : 0

  alarm_name          = "${var.name_prefix}-lifecycle-failures"
  alarm_description   = "alternat lifecycle Step Function had failed/timed-out/aborted executions. Investigate via the SFN console or CloudWatch Logs (vendedlogs/states/${var.name_prefix}-lifecycle)."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.alarm_evaluation_periods
  threshold           = var.alarm_threshold
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "anyFailure"
    label       = "AnyFailure"
    return_data = true
    expression  = "failed + timedOut + aborted"
  }
  metric_query {
    id = "failed"
    metric {
      namespace   = "AWS/States"
      metric_name = "ExecutionsFailed"
      period      = 300
      stat        = "Sum"
      dimensions = {
        StateMachineArn = aws_sfn_state_machine.lifecycle.arn
      }
    }
  }
  metric_query {
    id = "timedOut"
    metric {
      namespace   = "AWS/States"
      metric_name = "ExecutionsTimedOut"
      period      = 300
      stat        = "Sum"
      dimensions = {
        StateMachineArn = aws_sfn_state_machine.lifecycle.arn
      }
    }
  }
  metric_query {
    id = "aborted"
    metric {
      namespace   = "AWS/States"
      metric_name = "ExecutionsAborted"
      period      = 300
      stat        = "Sum"
      dimensions = {
        StateMachineArn = aws_sfn_state_machine.lifecycle.arn
      }
    }
  }

  alarm_actions = local.effective_alarm_actions
  ok_actions    = local.effective_alarm_actions

  tags = local.common_tags
}
