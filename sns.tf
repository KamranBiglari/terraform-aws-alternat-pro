resource "aws_sns_topic" "lifecycle" {
  name              = "${var.name_prefix}-lifecycle"
  kms_master_key_id = var.lifecycle_topic_kms_key_id
  tags              = local.common_tags
}

data "aws_iam_policy_document" "lifecycle_topic" {
  statement {
    sid     = "AllowAsgPublish"
    actions = ["sns:Publish"]
    principals {
      type        = "Service"
      identifiers = ["autoscaling.amazonaws.com"]
    }
    resources = [aws_sns_topic.lifecycle.arn]
  }
}

resource "aws_sns_topic_policy" "lifecycle" {
  arn    = aws_sns_topic.lifecycle.arn
  policy = data.aws_iam_policy_document.lifecycle_topic.json
}

# Role assumed by ASG to publish lifecycle hook events to the SNS topic.
data "aws_iam_policy_document" "asg_lifecycle_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["autoscaling.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "asg_lifecycle" {
  name               = "${var.name_prefix}-asg-lifecycle"
  assume_role_policy = data.aws_iam_policy_document.asg_lifecycle_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "asg_lifecycle" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.lifecycle.arn]
  }
}

resource "aws_iam_role_policy" "asg_lifecycle" {
  name   = "${var.name_prefix}-asg-lifecycle"
  role   = aws_iam_role.asg_lifecycle.id
  policy = data.aws_iam_policy_document.asg_lifecycle.json
}
