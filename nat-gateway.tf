resource "aws_nat_gateway" "this" {
  for_each = toset(local.azs_with_module_ngw)

  allocation_id     = local.ngw_eip_allocation_by_az[each.key]
  subnet_id         = local.public_subnet_id_by_az[each.key]
  connectivity_type = "public"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-${each.key}"
  })
}
