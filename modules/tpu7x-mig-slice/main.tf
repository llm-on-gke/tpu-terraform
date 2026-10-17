#------------------------------------------------------------------------------
# tpu7x-mig-slice
#
# Provisions a multi-host TPU7x (Ironwood) slice on Compute Engine as a
# managed instance group, following
# https://docs.cloud.google.com/compute/docs/tpus/create-tpu-mig-multi-host-slice
#
#   1. Instance template  (consumption option: on-demand / Spot / reservation-bound / flex-start)
#   2. Workload policy    (HIGH_THROUGHPUT + acceleratorTopology → VMs form ONE interconnected slice)
#   3. MIG                (BULK target-size policy, DO_NOTHING on failure, zonal or regional)
#------------------------------------------------------------------------------

locals {
  # ---- topology → sizing ---------------------------------------------------
  dims     = [for d in split("x", var.topology) : tonumber(d)]
  chips    = local.dims[0] * local.dims[1] * local.dims[2]
  vm_count = local.chips / var.chips_per_host

  target_size = var.target_size_override != null ? var.target_size_override : local.vm_count

  # ---- placement -----------------------------------------------------------
  # "us-central1-c" -> "us-central1", also handles zones such as "us-central1-ai1a".
  zone_region = var.zone != null ? join("-", slice(split("-", var.zone), 0, 2)) : null
  region      = coalesce(var.region, local.zone_region)

  is_zonal    = var.mig_type == "zonal"
  is_regional = var.mig_type == "regional"

  # ---- provisioning model --------------------------------------------------
  is_spot = var.provisioning_model == "SPOT"
  is_rb   = var.provisioning_model == "RESERVATION_BOUND"
  is_flex = var.provisioning_model == "FLEX_START"

  default_termination_action = (
    local.is_spot ? "STOP" :
    (local.is_rb || local.is_flex) ? "DELETE" :
    null
  )
  termination_action = var.instance_termination_action != null ? var.instance_termination_action : local.default_termination_action

  base_instance_name = coalesce(var.base_instance_name, var.name)

  labels = merge(
    {
      managed-by         = "terraform"
      tpu-accelerator    = "tpu7x"
      tpu-topology       = var.topology
      provisioning-model = lower(var.provisioning_model)
    },
    var.labels,
  )

  metadata = merge(
    var.enable_oslogin ? { enable-oslogin = "TRUE" } : {},
    var.metadata,
  )
}

#------------------------------------------------------------------------------
# 1. Instance template
#------------------------------------------------------------------------------
resource "google_compute_instance_template" "tpu" {
  project      = var.project_id
  name_prefix  = "${var.name}-"
  description  = var.description
  region       = local.region
  machine_type = var.machine_type
  tags         = var.network_tags
  labels       = local.labels

  disk {
    boot                   = true
    auto_delete            = true
    source_image           = var.source_image
    disk_type              = var.boot_disk_type
    disk_size_gb           = var.boot_disk_size_gb
    provisioned_iops       = var.boot_disk_provisioned_iops
    provisioned_throughput = var.boot_disk_provisioned_throughput
  }

  # Optional per-VM non-boot read-write Hyperdisk Balanced data disks.
  dynamic "disk" {
    for_each = range(var.data_disk_count)
    content {
      boot                   = false
      auto_delete            = var.data_disk_auto_delete
      device_name            = "data-disk-${disk.value}"
      disk_type              = var.data_disk_type
      disk_size_gb           = var.data_disk_size_gb
      mode                   = "READ_WRITE"
      type                   = "PERSISTENT"
      provisioned_iops       = var.data_disk_provisioned_iops
      provisioned_throughput = var.data_disk_provisioned_throughput
    }
  }

  network_interface {
    network            = var.network
    subnetwork         = var.subnetwork
    subnetwork_project = var.subnetwork_project
    nic_type           = var.nic_type

    dynamic "access_config" {
      for_each = var.enable_external_ip ? [1] : []
      content {}
    }
  }

  # TPU VMs must use TERMINATE for host maintenance.
  scheduling {
    on_host_maintenance         = "TERMINATE"
    provisioning_model          = var.provisioning_model
    preemptible                 = local.is_spot
    automatic_restart           = (local.is_spot || local.is_flex) ? false : true
    instance_termination_action = local.termination_action

    dynamic "max_run_duration" {
      for_each = var.max_run_duration_seconds != null ? [1] : []
      content {
        seconds = var.max_run_duration_seconds
      }
    }
  }

  # Target a specific reservation (required for RESERVATION_BOUND, optional for STANDARD).
  dynamic "reservation_affinity" {
    for_each = var.reservation_name != null ? [1] : []
    content {
      type = "SPECIFIC_RESERVATION"
      specific_reservation {
        key    = "compute.googleapis.com/reservation-name"
        values = [var.reservation_name]
      }
    }
  }

  service_account {
    email  = var.service_account_email
    scopes = var.service_account_scopes
  }

  metadata                = local.metadata
  metadata_startup_script = var.startup_script

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = !local.is_rb || var.reservation_name != null
      error_message = "provisioning_model = \"RESERVATION_BOUND\" requires reservation_name."
    }
    precondition {
      condition     = !local.is_flex || var.max_run_duration_seconds != null
      error_message = "provisioning_model = \"FLEX_START\" requires max_run_duration_seconds."
    }
    precondition {
      condition     = !local.is_zonal || var.zone != null
      error_message = "mig_type = \"zonal\" requires zone."
    }
    precondition {
      condition     = !local.is_regional || var.region != null
      error_message = "mig_type = \"regional\" requires region."
    }
    precondition {
      condition     = local.target_size == 0 || local.target_size == local.vm_count
      error_message = "target_size_override must be 0 or equal to the topology VM count (${local.vm_count}); a multi-host slice must be created as a whole."
    }
  }
}

#------------------------------------------------------------------------------
# 2. Workload policy — makes the MIG treat the VMs as a single ICI-connected slice
#------------------------------------------------------------------------------
resource "google_compute_resource_policy" "workload" {
  project     = var.project_id
  name        = "${var.name}-wp"
  region      = local.region
  description = var.description

  workload_policy {
    type                 = "HIGH_THROUGHPUT"
    accelerator_topology = var.topology
  }
}

#------------------------------------------------------------------------------
# 3a. Zonal MIG
#------------------------------------------------------------------------------
resource "google_compute_instance_group_manager" "zonal" {
  count = local.is_zonal ? 1 : 0

  project            = var.project_id
  name               = var.name
  description        = var.description
  zone               = var.zone
  base_instance_name = local.base_instance_name
  target_size        = local.target_size

  version {
    name              = "tpu7x"
    instance_template = google_compute_instance_template.tpu.self_link
  }

  # Create all hosts of the slice atomically.
  target_size_policy {
    mode = "BULK"
  }

  # Don't auto-repair individual hosts of a slice.
  instance_lifecycle_policy {
    default_action_on_failure = var.default_action_on_failure
  }

  resource_policies {
    workload_policy = google_compute_resource_policy.workload.self_link
  }

  wait_for_instances        = var.wait_for_instances
  wait_for_instances_status = "STABLE"

  timeouts {
    create = var.mig_timeouts.create
    update = var.mig_timeouts.update
    delete = var.mig_timeouts.delete
  }
}

#------------------------------------------------------------------------------
# 3b. Regional MIG — ANY_SINGLE_ZONE keeps the whole slice in one zone
#------------------------------------------------------------------------------
data "google_compute_zones" "regional" {
  count = local.is_regional && var.regional_zones == null ? 1 : 0

  project = var.project_id
  region  = var.region
}

locals {
  regional_zone_count = (
    local.is_regional
    ? (var.regional_zones != null ? length(var.regional_zones) : length(data.google_compute_zones.regional[0].names))
    : 0
  )
}

resource "google_compute_region_instance_group_manager" "regional" {
  count = local.is_regional ? 1 : 0

  project            = var.project_id
  name               = var.name
  description        = var.description
  region             = var.region
  base_instance_name = local.base_instance_name
  target_size        = local.target_size

  distribution_policy_target_shape = "ANY_SINGLE_ZONE"
  distribution_policy_zones        = var.regional_zones

  version {
    name              = "tpu7x"
    instance_template = google_compute_instance_template.tpu.self_link
  }

  target_size_policy {
    mode = "BULK"
  }

  instance_lifecycle_policy {
    default_action_on_failure = var.default_action_on_failure
  }

  resource_policies {
    workload_policy = google_compute_resource_policy.workload.self_link
  }

  # Never redistribute hosts of a slice across zones; updates are opportunistic
  # (a slice must be recreated as a whole, rolling updates are meaningless).
  update_policy {
    type                         = "OPPORTUNISTIC"
    minimal_action               = "REPLACE"
    instance_redistribution_type = "NONE"
    max_surge_fixed              = 0
    max_unavailable_fixed        = max(local.vm_count, local.regional_zone_count)
  }

  wait_for_instances        = var.wait_for_instances
  wait_for_instances_status = "STABLE"

  timeouts {
    create = var.mig_timeouts.create
    update = var.mig_timeouts.update
    delete = var.mig_timeouts.delete
  }
}
