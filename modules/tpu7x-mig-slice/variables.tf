#------------------------------------------------------------------------------
# tpu7x-mig-slice — input variables
#------------------------------------------------------------------------------

#---------------------------------------
# Identity / placement
#---------------------------------------
variable "project_id" {
  description = "GCP project ID in which to create the TPU slice."
  type        = string
}

variable "name" {
  description = <<-EOT
    Base name for all resources created by this module (instance template,
    workload policy, MIG). Must be RFC1035 compliant (lowercase letters,
    digits and hyphens; start with a letter). Keep it <= 40 characters so
    that the derived names stay within GCE limits.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,38}[a-z0-9])?$", var.name))
    error_message = "name must be RFC1035 compliant and at most 40 characters long."
  }
}

variable "zone" {
  description = <<-EOT
    Zone for a zonal MIG (e.g. "us-central1-c"). Required when
    mig_type = "zonal". The workload policy region is derived from this zone
    unless `region` is set explicitly.
  EOT
  type        = string
  default     = null
}

variable "region" {
  description = <<-EOT
    Region for a regional MIG and for the workload policy. Optional for zonal
    MIGs (derived from `zone`); required when mig_type = "regional".
  EOT
  type        = string
  default     = null
}

variable "mig_type" {
  description = <<-EOT
    "zonal" (default) creates a zonal MIG in `zone`. "regional" creates a
    regional MIG in `region` with target shape ANY_SINGLE_ZONE so the whole
    slice lands in one zone (optionally constrained via `regional_zones`).
  EOT
  type        = string
  default     = "zonal"

  validation {
    condition     = contains(["zonal", "regional"], var.mig_type)
    error_message = "mig_type must be \"zonal\" or \"regional\"."
  }
}

variable "regional_zones" {
  description = "Optional list of zones a regional MIG may place the slice in. Ignored for zonal MIGs."
  type        = list(string)
  default     = null
}

#---------------------------------------
# TPU slice shape
#---------------------------------------
variable "topology" {
  description = <<-EOT
    TPU7x (Ironwood) 3D slice topology, e.g. "2x2x2", "4x4x4", "8x8x16".
    Determines the MIG size: each tpu7x-standard-4t host has 4 chips, so
    VM count = (x*y*z)/4. Multi-host topologies supported by TPU7x:
    2x2x2 (8 chips, 2 VMs), 2x2x4 (16, 4), 2x4x4 (32, 8), 4x4x4 (64, 16),
    4x4x8 (128, 32), 4x8x8 (256, 64), 8x8x8 (512, 128), 8x8x16 (1024, 256),
    8x16x16 (2048, 512).
  EOT
  type        = string

  validation {
    condition     = can(regex("^[0-9]+x[0-9]+x[0-9]+$", var.topology))
    error_message = "topology must be of the form AxBxC, e.g. \"2x2x2\"."
  }

  validation {
    condition = (
      can(regex("^[0-9]+x[0-9]+x[0-9]+$", var.topology)) &&
      (tonumber(split("x", var.topology)[0]) * tonumber(split("x", var.topology)[1]) * tonumber(split("x", var.topology)[2])) % 4 == 0 &&
      (tonumber(split("x", var.topology)[0]) * tonumber(split("x", var.topology)[1]) * tonumber(split("x", var.topology)[2])) >= 8
    )
    error_message = "topology chip count (x*y*z) must be a multiple of 4 and >= 8 for a multi-host slice (2x2x1 is single-host)."
  }
}

variable "machine_type" {
  description = <<-EOT
    TPU7x machine type. All TPU7x topologies use the 4-chip full-host
    "tpu7x-standard-4t" machine type (224 vCPU / 960 GB). Override only if
    Google documents another multi-host TPU7x machine type.
  EOT
  type        = string
  default     = "tpu7x-standard-4t"

  validation {
    condition     = can(regex("^tpu7x-.*-4t$", var.machine_type))
    error_message = "machine_type must be a 4-chip TPU7x host type (tpu7x-*-4t)."
  }
}

variable "chips_per_host" {
  description = "Number of TPU chips per host VM. 4 for tpu7x-*-4t. Only change if the machine type changes."
  type        = number
  default     = 4
}

variable "target_size_override" {
  description = <<-EOT
    Optional override for the MIG target size. Defaults to the VM count
    derived from `topology`. Useful to pre-create the MIG with size 0 before
    a calendar reservation becomes active and resize it later.
  EOT
  type        = number
  default     = null
}

#---------------------------------------
# Consumption option / provisioning model
#---------------------------------------
variable "provisioning_model" {
  description = <<-EOT
    How to obtain capacity:
      * "STANDARD"          — on-demand (optionally consume a standard reservation via `reservation_name`).
      * "SPOT"              — Spot VMs (preemptible, discounted).
      * "RESERVATION_BOUND" — consume a specific reservation, e.g. the auto-created
                              reservation of a DWS calendar-mode future reservation.
                              Requires `reservation_name`.
      * "FLEX_START"        — DWS flex-start; requires `max_run_duration_seconds`.
  EOT
  type        = string
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "SPOT", "RESERVATION_BOUND", "FLEX_START"], var.provisioning_model)
    error_message = "provisioning_model must be one of STANDARD, SPOT, RESERVATION_BOUND, FLEX_START."
  }
}

variable "reservation_name" {
  description = <<-EOT
    Name of an EXISTING reservation to consume. Required for RESERVATION_BOUND.

    DWS calendar-mode future reservation: pass the name of the reservation that
    Compute Engine auto-created when the request was approved. It is the
    `reservationName` of the future reservation, which defaults to the future
    reservation's own name:
      gcloud compute future-reservations describe FR_NAME --zone ZONE --format='value(reservationName)'
    The reservation must be in the MIG's zone (regional MIGs: constrain with
    `regional_zones`). It has 0 capacity before the window's start time, so
    create the MIG with `target_size_override = 0` until then.

    Shared reservation owned by another project:
      projects/OWNER_PROJECT/reservations/RESERVATION_NAME
    All-Capacity-mode reservation block / sub-block:
      RESERVATION/reservationBlocks/BLOCK
      RESERVATION/reservationBlocks/BLOCK/reservationSubBlocks/SUBBLOCK

    With provisioning_model = "STANDARD" the VMs target the reservation with
    SPECIFIC_RESERVATION affinity (standard, non-calendar reservations).
  EOT
  type        = string
  default     = null
}

variable "instance_termination_action" {
  description = <<-EOT
    Action when a Spot VM is preempted / a reservation-bound or flex-start VM
    reaches its end. Defaults follow the Google docs: STOP for SPOT, DELETE
    for RESERVATION_BOUND and FLEX_START, unset for STANDARD.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.instance_termination_action == null || contains(["STOP", "DELETE"], coalesce(var.instance_termination_action, "STOP"))
    error_message = "instance_termination_action must be STOP or DELETE."
  }
}

variable "max_run_duration_seconds" {
  description = "Maximum run duration in seconds (required for FLEX_START, optional for SPOT, 1h–7d)."
  type        = number
  default     = null
}

#---------------------------------------
# Boot disk / image
#---------------------------------------
variable "source_image" {
  description = <<-EOT
    Boot image for the TPU VMs. Defaults to the TPU7x Ubuntu 24.04 accelerator
    image family published by Google
    (projects/ubuntu-os-accelerator-images/global/images/family/ubuntu-accel-2404-amd64-tpu-tpu7x).
  EOT
  type        = string
  default     = "projects/ubuntu-os-accelerator-images/global/images/family/ubuntu-accel-2404-amd64-tpu-tpu7x"
}

variable "boot_disk_type" {
  description = "Boot disk type. TPU7x defaults to Hyperdisk Balanced; Hyperdisk ML is also supported."
  type        = string
  default     = "hyperdisk-balanced"
}

variable "boot_disk_size_gb" {
  description = "Boot disk size in GB."
  type        = number
  default     = 100
}

variable "boot_disk_provisioned_iops" {
  description = "Optional provisioned IOPS for Hyperdisk boot disks (null = provider/API default)."
  type        = number
  default     = null
}

variable "boot_disk_provisioned_throughput" {
  description = "Optional provisioned throughput (MB/s) for Hyperdisk boot disks (null = default)."
  type        = number
  default     = null
}

#---------------------------------------
# Non-boot data disks (Hyperdisk Balanced per VM)
#---------------------------------------
variable "data_disk_count" {
  description = <<-EOT
    Number of non-boot read-write Hyperdisk Balanced data disks to create and
    attach per VM from the instance template (0–63; tpu7x-standard-4t supports
    up to 64 total Hyperdisk volumes including the boot disk). Each VM in the
    slice receives its own independent read-write data disk(s).
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.data_disk_count >= 0 && var.data_disk_count <= 63 && floor(var.data_disk_count) == var.data_disk_count
    error_message = "data_disk_count must be an integer between 0 and 63."
  }
}

variable "data_disk_type" {
  description = "Disk type for non-boot per-VM data disks. Defaults to hyperdisk-balanced."
  type        = string
  default     = "hyperdisk-balanced"
}

variable "data_disk_size_gb" {
  description = <<-EOT
    Size in GiB for each non-boot Hyperdisk Balanced data disk (4–65536 GiB).
    Note: Hyperdisk Balanced allows up to 500 IOPS per GiB (capped at 160,000
    IOPS per disk), so at least 320 GiB is required to provision 160,000 IOPS.
  EOT
  type        = number
  default     = 500

  validation {
    condition     = var.data_disk_size_gb >= 4 && var.data_disk_size_gb <= 65536
    error_message = "data_disk_size_gb must be between 4 and 65536 GiB."
  }
}

variable "data_disk_provisioned_iops" {
  description = <<-EOT
    Optional provisioned IOPS for each non-boot Hyperdisk Balanced data disk
    (null = API default). Up to min(500 * size_gb, 160,000) IOPS per disk;
    tpu7x-standard-4t caps total VM performance at 320,000 IOPS across all disks.
  EOT
  type        = number
  default     = null
}

variable "data_disk_provisioned_throughput" {
  description = <<-EOT
    Optional provisioned throughput (MiB/s) for each non-boot Hyperdisk Balanced
    data disk (null = API default). Up to min(2,400, provisioned_iops / 4) MiB/s
    per disk; tpu7x-standard-4t caps total VM throughput at 7,200 MiB/s across all disks.
  EOT
  type        = number
  default     = null
}

variable "data_disk_auto_delete" {
  description = "Whether non-boot per-VM data disks are automatically deleted when the VM is deleted."
  type        = bool
  default     = true
}

#---------------------------------------
# Networking
#---------------------------------------
variable "network" {
  description = "VPC network name or self link."
  type        = string
  default     = "default"
}

variable "subnetwork" {
  description = "Subnetwork name or self link. If null, the auto-mode subnet of `network` in the MIG region is used."
  type        = string
  default     = null
}

variable "subnetwork_project" {
  description = "Project that owns the subnetwork (for Shared VPC). Defaults to project_id."
  type        = string
  default     = null
}

variable "nic_type" {
  description = "vNIC type. GVNIC is recommended for TPU VMs."
  type        = string
  default     = "GVNIC"
}

variable "enable_external_ip" {
  description = "Attach an ephemeral external IP to each TPU VM."
  type        = bool
  default     = false
}

variable "network_tags" {
  description = "Network tags applied to the TPU VMs."
  type        = list(string)
  default     = []
}

#---------------------------------------
# Identity / metadata / startup
#---------------------------------------
variable "service_account_email" {
  description = "Service account email for the TPU VMs. null = project default Compute Engine service account."
  type        = string
  default     = null
}

variable "service_account_scopes" {
  description = "OAuth scopes for the VM service account."
  type        = list(string)
  default     = ["https://www.googleapis.com/auth/cloud-platform"]
}

variable "metadata" {
  description = "Additional instance metadata key/value pairs."
  type        = map(string)
  default     = {}
}

variable "startup_script" {
  description = "Optional startup script content."
  type        = string
  default     = null
}

variable "enable_oslogin" {
  description = "Set enable-oslogin=TRUE in instance metadata."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Labels applied to the VMs (merged with module-generated labels)."
  type        = map(string)
  default     = {}
}

#---------------------------------------
# MIG behaviour
#---------------------------------------
variable "base_instance_name" {
  description = "Base instance name for the MIG VMs. Defaults to `name`."
  type        = string
  default     = null
}

variable "default_action_on_failure" {
  description = "MIG instanceLifecyclePolicy.defaultActionOnFailure. Google recommends DO_NOTHING for multi-host TPU slices."
  type        = string
  default     = "DO_NOTHING"

  validation {
    condition     = contains(["DO_NOTHING", "REPAIR"], var.default_action_on_failure)
    error_message = "default_action_on_failure must be DO_NOTHING or REPAIR."
  }
}

variable "wait_for_instances" {
  description = "Make Terraform wait until all MIG instances are created and STABLE before returning."
  type        = bool
  default     = false
}

variable "mig_timeouts" {
  description = "Timeouts for MIG create/update/delete (relevant when wait_for_instances = true)."
  type = object({
    create = optional(string, "30m")
    update = optional(string, "30m")
    delete = optional(string, "30m")
  })
  default = {}
}

variable "description" {
  description = "Description applied to the created resources."
  type        = string
  default     = "TPU7x (Ironwood) multi-host slice managed by Terraform"
}
