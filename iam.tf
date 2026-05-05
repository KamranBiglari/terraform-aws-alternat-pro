# =====================================================================
# NAT instance role
# =====================================================================
data "aws_iam_policy_document" "nat_instance_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nat_instance" {
  name               = "${var.name_prefix}-nat-instance"
  assume_role_policy = data.aws_iam_policy_document.nat_instance_assume.json
  tags               = local.common_tags
}

resource "aws_iam_instance_profile" "nat_instance" {
  name = "${var.name_prefix}-nat-instance"
  role = aws_iam_role.nat_instance.name
  tags = local.common_tags
}

data "aws_iam_policy_document" "nat_instance" {
  statement {
    sid = "RouteAndEipManagement"
    actions = [
      "ec2:ReplaceRoute",
      "ec2:CreateRoute",
      "ec2:DescribeRouteTables",
      "ec2:DescribeAddresses",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeInstances",
      "ec2:AssociateAddress",
      "ec2:DisassociateAddress",
      "ec2:ModifyInstanceAttribute",
      "ec2:CreateTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "nat_instance" {
  name   = "${var.name_prefix}-nat-instance"
  role   = aws_iam_role.nat_instance.id
  policy = data.aws_iam_policy_document.nat_instance.json
}

resource "aws_iam_role_policy_attachment" "nat_instance_ssm" {
  role       = aws_iam_role.nat_instance.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "nat_instance_extra" {
  for_each   = toset(var.additional_instance_policies)
  role       = aws_iam_role.nat_instance.name
  policy_arn = each.value
}

# =====================================================================
# Probe Lambda role
# =====================================================================
data "aws_iam_policy_document" "probe_lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "probe_lambda" {
  name               = "${var.name_prefix}-probe-lambda"
  assume_role_policy = data.aws_iam_policy_document.probe_lambda_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "probe_lambda_vpc" {
  role       = aws_iam_role.probe_lambda.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# The probe Lambda has zero AWS API dependencies — every piece of state it
# needs (route tables, live ENI, lock) is fetched by the Step Function in
# the service plane and passed in. The only attached policy is the standard
# VPC ENI management policy required by Lambda's vpc_config.

# =====================================================================
# Lifecycle dispatcher Lambda role
# =====================================================================
resource "aws_iam_role" "lifecycle_dispatcher" {
  name               = "${var.name_prefix}-lifecycle-dispatcher"
  assume_role_policy = data.aws_iam_policy_document.probe_lambda_assume.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "lifecycle_dispatcher_basic" {
  role       = aws_iam_role.lifecycle_dispatcher.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lifecycle_dispatcher" {
  statement {
    sid       = "StartLifecycleSfn"
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.lifecycle.arn]
  }
}

resource "aws_iam_role_policy" "lifecycle_dispatcher" {
  name   = "${var.name_prefix}-lifecycle-dispatcher"
  role   = aws_iam_role.lifecycle_dispatcher.id
  policy = data.aws_iam_policy_document.lifecycle_dispatcher.json
}

# =====================================================================
# Step Function role (shared by both state machines)
# =====================================================================
data "aws_iam_policy_document" "sfn_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "sfn" {
  name               = "${var.name_prefix}-sfn"
  assume_role_policy = data.aws_iam_policy_document.sfn_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "sfn" {
  statement {
    sid = "InvokeProbeLambdas"
    actions = [
      "lambda:InvokeFunction",
    ]
    resources = [for fn in aws_lambda_function.probe : fn.arn]
  }

  statement {
    sid = "EC2DescribeAndRoute"
    actions = [
      "ec2:ReplaceRoute",
      "ec2:CreateRoute",
      "ec2:DescribeRouteTables",
      "ec2:DescribeNetworkInterfaces",
    ]
    resources = ["*"]
  }

  statement {
    sid = "Lock"
    actions = [
      "dynamodb:UpdateItem",
      "dynamodb:GetItem",
      "dynamodb:PutItem",
    ]
    resources = [aws_dynamodb_table.lock.arn]
  }

  dynamic "statement" {
    for_each = var.enable_nat_restore_ssm_check ? [1] : []
    content {
      sid = "SsmSendVerify"
      actions = [
        "ssm:SendCommand",
      ]
      resources = [
        aws_ssm_document.verify[0].arn,
        "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:instance/*",
      ]
    }
  }

  dynamic "statement" {
    for_each = var.enable_nat_restore_ssm_check ? [1] : []
    content {
      sid = "SsmReadInvocations"
      actions = [
        "ssm:ListCommandInvocations",
        "ssm:GetCommandInvocation",
      ]
      resources = ["*"]
    }
  }

  statement {
    sid = "PutMetrics"
    actions = [
      "cloudwatch:PutMetricData",
    ]
    resources = ["*"]
  }

  statement {
    sid = "Logging"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "sfn" {
  name   = "${var.name_prefix}-sfn"
  role   = aws_iam_role.sfn.id
  policy = data.aws_iam_policy_document.sfn.json
}

# =====================================================================
# EventBridge -> SFN role
# =====================================================================
data "aws_iam_policy_document" "eventbridge_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eventbridge" {
  name               = "${var.name_prefix}-eventbridge"
  assume_role_policy = data.aws_iam_policy_document.eventbridge_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "eventbridge" {
  statement {
    actions   = ["states:StartExecution"]
    resources = [aws_sfn_state_machine.health_check.arn]
  }
}

resource "aws_iam_role_policy" "eventbridge" {
  name   = "${var.name_prefix}-eventbridge"
  role   = aws_iam_role.eventbridge.id
  policy = data.aws_iam_policy_document.eventbridge.json
}
