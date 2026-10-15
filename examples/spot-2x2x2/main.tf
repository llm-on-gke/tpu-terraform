#------------------------------------------------------------------------------
# Example: 2x2x2 TPU7x (Ironwood) slice on Spot VMs
#   8 chips → 2 × tpu7x-standard-4t hosts in a single zonal MIG.
#------------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.28.0, < 9.0.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = local.region
  zone    = var.zone
}

locals {
  region = join("-", slice(split("-", var.zone), 0, 2))
}

module "tpu_slice" {
  source = "../../modules/tpu7x-mig-slice"

  project_id = var.project_id
  name       = var.name
  zone       = var.zone
  mig_type   = "zonal"

  topology           = var.topology # "2x2x2" → 2 VMs
  provisioning_model = "SPOT"
  # Spot default per Google docs: STOP on preemption. Use "DELETE" if you
  # prefer the MIG to simply recreate the slice later.
  instance_termination_action = var.instance_termination_action

  network            = var.network
  subnetwork         = var.subnetwork
  enable_external_ip = var.enable_external_ip
  network_tags       = var.network_tags

  boot_disk_size_gb = var.boot_disk_size_gb

  labels = {
    environment = "test"
    example     = "spot-2x2x2"
  }

  # Block until both hosts are RUNNING & the MIG is STABLE so the apply itself
  # proves the slice came up (Spot capacity permitting).
  wait_for_instances = var.wait_for_instances
  mig_timeouts = {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
