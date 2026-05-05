resource "aws_dynamodb_table" "lock" {
  name         = "${var.name_prefix}-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "az"

  attribute {
    name = "az"
    type = "S"
  }

  ttl {
    attribute_name = "ttl_at"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = false
  }

  tags = local.common_tags
}
