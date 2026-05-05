# Two parallel resources for each EIP class because lifecycle.prevent_destroy
# cannot be variable-driven. Toggle with var.prevent_destroy_eips.

resource "aws_eip" "nat_instance_protected" {
  for_each = toset(local.instance_eip_create_protected)

  domain = "vpc"
  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-instance-${each.key}"
    Role = "nat-instance"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_eip" "nat_instance_unprotected" {
  for_each = toset(local.instance_eip_create_unprotected)

  domain = "vpc"
  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-instance-${each.key}"
    Role = "nat-instance"
  })
}

resource "aws_eip" "nat_gateway_protected" {
  for_each = toset(local.ngw_eip_create_protected)

  domain = "vpc"
  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-ngw-${each.key}"
    Role = "nat-gateway"
  })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_eip" "nat_gateway_unprotected" {
  for_each = toset(local.ngw_eip_create_unprotected)

  domain = "vpc"
  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-ngw-${each.key}"
    Role = "nat-gateway"
  })
}
