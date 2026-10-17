#------------------------------------------------------------------------------
# Example: TPU7x slice on an EXISTING DWS calendar-mode reservation
#
# Prerequisite: a calendar-mode future reservation that Google has approved.
# When approved, Compute Engine auto-creates a reservation (name = the future
# reservation's `reservationName`, which defaults to the future reservation
# name). Pass that name as `reservation_name`; the slice consumes it with the
# RESERVATION_BOUND provisioning model, as the docs require.
#
#   gcloud compute future-reservations describe FR_NAME --zone ZONE \
#     --format='value(reservationName,status.procurementStatus,timeWindow)'
#
# Timeline:
#   start_time: capacity delivered  ──► apply with activate_slice=true
#   end_time:   reservation auto-deleted, VMs DELETED (instance_termination_action)
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
  zone       = var.zone # must be the reservation's zone
  mig_type   = "zonal"

  topology           = var.topology
  provisioning_model = "RESERVATION_BOUND"
  reservation_name   = var.reservation_name
  # Per docs: reservation-bound VMs are DELETED at the reservation end time.
  instance_termination_action = "DELETE"

  # Before the reservation's start time it has 0 capacity and VM creation
  # fails. Keep the MIG at 0 hosts until the window opens, then re-apply with
  # -var activate_slice=true.
  target_size_override = var.activate_slice ? null : 0

  network            = var.network
  subnetwork         = var.subnetwork
  enable_external_ip = var.enable_external_ip
  network_tags       = var.network_tags

  source_image                     = var.source_image
  boot_disk_size_gb                = var.boot_disk_size_gb
  data_disk_count                  = var.data_disk_count
  data_disk_size_gb                = var.data_disk_size_gb
  data_disk_provisioned_iops       = var.data_disk_provisioned_iops
  data_disk_provisioned_throughput = var.data_disk_provisioned_throughput
  metadata                         = var.metadata
  startup_script                   = var.startup_script

  labels = {
    example = "calendar-reservation"
  }

  wait_for_instances = var.activate_slice
}
