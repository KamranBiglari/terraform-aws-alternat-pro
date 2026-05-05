# Operator-facing SSM Automation runbook for manually flipping routes.
# Wraps the health-check Step Function so an operator can trigger a
# force-fallback / force-ec2 / health-check from:
#   * `aws ssm start-automation-execution --document-name <name> --parameters Action=force-fallback,AZ=eu-west-1a`
#   * Systems Manager → Automation → Execute automation (form UI)
#   * Any other system that can call ssm:StartAutomationExecution
#
# The automation step uses aws:executeAwsApi to call states:StartExecution
# on the health-check SFN. No EC2 instance is targeted (it's a control-plane
# automation), so it works even when every NAT instance is unhealthy.

data "aws_iam_policy_document" "ssm_automation_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm_automation" {
  name               = "${var.name_prefix}-ssm-automation"
  assume_role_policy = data.aws_iam_policy_document.ssm_automation_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "ssm_automation" {
  statement {
    sid       = "StartHealthCheckSfn"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.health_check.arn]
  }
}

resource "aws_iam_role_policy" "ssm_automation" {
  name   = "${var.name_prefix}-ssm-automation"
  role   = aws_iam_role.ssm_automation.id
  policy = data.aws_iam_policy_document.ssm_automation.json
}

resource "aws_ssm_document" "route_control" {
  name            = "${var.name_prefix}-route-control"
  document_type   = "Automation"
  document_format = "YAML"
  tags            = local.common_tags

  content = yamlencode({
    schemaVersion = "0.3"
    description   = "Manually switch alternat routing for one AZ (or all) to the fallback target or back to the EC2 NAT instance."
    assumeRole    = aws_iam_role.ssm_automation.arn

    parameters = {
      Action = {
        type          = "String"
        description   = "force-fallback flips the route to the configured fallback target. force-ec2 flips it back to the live NAT instance ENI (bypasses the SSM verify gate). health-check runs the same logic the EventBridge tick runs."
        allowedValues = ["force-fallback", "force-ec2", "health-check"]
      }
      AZ = {
        type        = "String"
        description = "Availability Zone short-name (e.g. eu-west-1a) or 'all' to fan out across every configured AZ."
        default     = "all"
      }
    }

    mainSteps = [
      {
        name        = "StartHealthCheckExecution"
        action      = "aws:executeAwsApi"
        description = "Call states:StartExecution on the alternat health-check state machine."
        inputs = {
          Service         = "stepfunctions"
          Api             = "StartExecution"
          stateMachineArn = aws_sfn_state_machine.health_check.arn
          input           = "{\"action\":\"{{Action}}\",\"az\":\"{{AZ}}\"}"
        }
        outputs = [
          {
            Name     = "ExecutionArn"
            Selector = "$.executionArn"
            Type     = "String"
          }
        ]
      }
    ]

    outputs = [
      "StartHealthCheckExecution.ExecutionArn",
    ]
  })
}
