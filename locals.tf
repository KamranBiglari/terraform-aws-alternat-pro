locals {
  az_keys = [for m in var.vpc_az_maps : m.az]
  az_map  = { for m in var.vpc_az_maps : m.az => m }

  azs_with_module_ngw = [for m in var.vpc_az_maps : m.az if m.create_nat_gateway]

  instance_eip_byo = {
    for m in var.vpc_az_maps : m.az => m.instance_eip_allocation_id
    if m.instance_eip_allocation_id != null
  }
  instance_eip_create_protected = var.prevent_destroy_eips ? [
    for m in var.vpc_az_maps : m.az if m.instance_eip_allocation_id == null
  ] : []
  instance_eip_create_unprotected = var.prevent_destroy_eips ? [] : [
    for m in var.vpc_az_maps : m.az if m.instance_eip_allocation_id == null
  ]

  ngw_eip_byo = {
    for m in var.vpc_az_maps : m.az => m.nat_eip_allocation_id
    if m.create_nat_gateway && m.nat_eip_allocation_id != null
  }
  ngw_eip_create_protected = var.prevent_destroy_eips ? [
    for m in var.vpc_az_maps : m.az if m.create_nat_gateway && m.nat_eip_allocation_id == null
  ] : []
  ngw_eip_create_unprotected = var.prevent_destroy_eips ? [] : [
    for m in var.vpc_az_maps : m.az if m.create_nat_gateway && m.nat_eip_allocation_id == null
  ]

  # Resolved AZ -> instance EIP allocation ID (BYO wins over module-created).
  eip_allocation_by_az = {
    for az in local.az_keys : az => coalesce(
      lookup(local.instance_eip_byo, az, null),
      try(aws_eip.nat_instance_protected[az].id, null),
      try(aws_eip.nat_instance_unprotected[az].id, null),
    )
  }

  # Resolved AZ -> NGW EIP allocation ID (only for AZs that create a module-managed NGW).
  ngw_eip_allocation_by_az = {
    for az in local.azs_with_module_ngw : az => coalesce(
      lookup(local.ngw_eip_byo, az, null),
      try(aws_eip.nat_gateway_protected[az].id, null),
      try(aws_eip.nat_gateway_unprotected[az].id, null),
    )
  }

  # Resolved AZ -> { kind, target_id } the SFN uses to write the fallback route.
  # For module-managed NGWs the id is filled in from aws_nat_gateway after apply.
  fallback_target_by_az = {
    for m in var.vpc_az_maps : m.az => {
      kind = m.fallback.kind
      target_id = (
        m.fallback.kind == "nat_gateway" ? try(aws_nat_gateway.this[m.az].id, "") :
        m.fallback.kind == "existing_nat_gateway" ? m.fallback.nat_gateway_id :
        m.fallback.kind == "transit_gateway" ? m.fallback.transit_gateway_id :
        m.fallback.kind == "network_interface" ? m.fallback.network_interface_id :
        ""
      )
    }
  }

  route_table_ids_by_az    = { for m in var.vpc_az_maps : m.az => m.route_table_ids }
  private_subnet_ids_by_az = { for m in var.vpc_az_maps : m.az => m.private_subnet_ids }
  public_subnet_id_by_az   = { for m in var.vpc_az_maps : m.az => m.public_subnet_id }

  common_tags = merge(var.tags, {
    Module    = "alternat"
    ManagedBy = "terraform"
  })

  resolved_ami_id = var.nat_ami_id != null ? var.nat_ami_id : data.aws_ssm_parameter.al2023_arm64[0].value
}
