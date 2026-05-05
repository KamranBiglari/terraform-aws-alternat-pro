resource "aws_security_group" "nat_instance" {
  name        = "${var.name_prefix}-nat-instance"
  description = "Security group for the NAT instances managed by ${var.name_prefix}."
  vpc_id      = var.vpc_id
  tags        = local.common_tags
}

resource "aws_vpc_security_group_egress_rule" "nat_instance_all" {
  security_group_id = aws_security_group.nat_instance.id
  description       = "Allow all egress so the NAT instance can reach the internet."
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "nat_instance_vpc" {
  security_group_id = aws_security_group.nat_instance.id
  description       = "Allow all traffic from the VPC CIDR (private subnets) for NAT egress."
  ip_protocol       = "-1"
  cidr_ipv4         = data.aws_vpc.this.cidr_block
}

resource "aws_vpc_security_group_ingress_rule" "nat_instance_extra" {
  for_each = toset(var.ingress_security_group_ids)

  security_group_id            = aws_security_group.nat_instance.id
  description                  = "Allow ingress from caller-supplied security group ${each.key}."
  ip_protocol                  = "-1"
  referenced_security_group_id = each.value
}

resource "aws_launch_template" "this" {
  for_each = toset(local.az_keys)

  name_prefix   = "${var.name_prefix}-${each.key}-"
  image_id      = local.resolved_ami_id
  instance_type = var.nat_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    arn = aws_iam_instance_profile.nat_instance.arn
  }

  vpc_security_group_ids = [aws_security_group.nat_instance.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = true
  }

  dynamic "block_device_mappings" {
    for_each = var.nat_instance_block_devices
    content {
      device_name  = block_device_mappings.value.device_name
      no_device    = try(block_device_mappings.value.no_device, null)
      virtual_name = try(block_device_mappings.value.virtual_name, null)
      dynamic "ebs" {
        for_each = try([block_device_mappings.value.ebs], [])
        content {
          delete_on_termination = try(ebs.value.delete_on_termination, true)
          encrypted             = try(ebs.value.encrypted, true)
          iops                  = try(ebs.value.iops, null)
          kms_key_id            = try(ebs.value.kms_key_id, null)
          snapshot_id           = try(ebs.value.snapshot_id, null)
          throughput            = try(ebs.value.throughput, null)
          volume_size           = try(ebs.value.volume_size, null)
          volume_type           = try(ebs.value.volume_type, "gp3")
        }
      }
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/user-data.sh.tftpl", {
    eip_allocation_id   = local.eip_allocation_by_az[each.key]
    route_table_ids     = local.route_table_ids_by_az[each.key]
    region              = data.aws_region.current.region
    az                  = each.key
    name_prefix         = var.name_prefix
    extra               = var.extra_user_data
    write_route_on_boot = !var.start_in_observation_mode
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.common_tags, {
      Name = "${var.name_prefix}-${each.key}"
      AZ   = each.key
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(local.common_tags, {
      Name = "${var.name_prefix}-${each.key}"
    })
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "this" {
  for_each = toset(local.az_keys)

  name_prefix         = "${var.name_prefix}-${each.key}-"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = [local.public_subnet_id_by_az[each.key]]

  max_instance_lifetime     = var.max_instance_lifetime
  health_check_type         = "EC2"
  health_check_grace_period = 60

  launch_template {
    id      = aws_launch_template.this[each.key].id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-${each.key}"
    propagate_at_launch = true
  }

  tag {
    key                 = "AZ"
    value               = each.key
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.common_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_lifecycle_hook" "terminating" {
  for_each = aws_autoscaling_group.this

  name                    = "${var.name_prefix}-${each.key}-terminating"
  autoscaling_group_name  = each.value.name
  lifecycle_transition    = "autoscaling:EC2_INSTANCE_TERMINATING"
  default_result          = "CONTINUE"
  heartbeat_timeout       = 60
  notification_target_arn = aws_sns_topic.lifecycle.arn
  role_arn                = aws_iam_role.asg_lifecycle.arn
}
