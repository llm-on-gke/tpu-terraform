variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "zone" {
  description = "Zone of the calendar reservation (the slice is created in the same zone)."
  type        = string
  default     = "us-central1-c"
}

variable "name" {
  description = "Base name for all resources."
  type        = string
  default     = "tpu7x-cal"
}

variable "topology" {
  description = "TPU7x slice topology, e.g. 2x2x2 (8 chips), 2x2x4 (16 chips), 2x4x4 (32 chips), 4x4x4 (64 chips), 8x8x8 (512 chips). Can match the full reservation or a smaller sub-slice that fits within the reservation."
  type        = string
  default     = "4x4x4"
}

variable "reservation_name" {
  description = <<-EOT
    Name of the auto-created reservation of your approved calendar-mode future
    reservation (defaults to the future reservation's name):
      gcloud compute future-reservations describe FR --zone ZONE --format='value(reservationName)'
  EOT
  type        = string
}

variable "activate_slice" {
  description = <<-EOT
    false → create the MIG with target size 0 (safe before the reservation's start time).
    true  → scale the MIG to the full slice and wait for it to be STABLE.
  EOT
  type        = bool
  default     = false
}

variable "network" {
  description = "VPC network."
  type        = string
  default     = "default"
}

variable "subnetwork" {
  description = "Subnetwork (required for custom-mode VPCs)."
  type        = string
  default     = null
}

variable "enable_external_ip" {
  description = "Give each host an external IP."
  type        = bool
  default     = false
}

variable "network_tags" {
  description = "Network tags."
  type        = list(string)
  default     = []
}

variable "boot_disk_size_gb" {
  description = "Boot disk size (Hyperdisk Balanced)."
  type        = number
  default     = 100
}

variable "data_disk_count" {
  description = "Number of non-boot read-write Hyperdisk Balanced data disks to attach per VM (0–63)."
  type        = number
  default     = 0
}

variable "data_disk_size_gb" {
  description = "Size in GiB of each non-boot Hyperdisk Balanced data disk (>= 320 GiB required for 160,000 IOPS max per disk)."
  type        = number
  default     = 500
}

variable "data_disk_provisioned_iops" {
  description = "Optional provisioned IOPS per non-boot Hyperdisk Balanced disk (up to 160,000 per disk; 320,000 VM total cap on tpu7x-standard-4t)."
  type        = number
  default     = null
}

variable "data_disk_provisioned_throughput" {
  description = "Optional provisioned throughput (MiB/s) per non-boot Hyperdisk Balanced disk (up to 2,400 MiB/s per disk; 7,200 MiB/s VM total cap on tpu7x-standard-4t)."
  type        = number
  default     = null
}

variable "source_image" {
  description = "Boot image or image family for the TPU VMs (e.g. default Ubuntu accelerator image or a custom Debian 12 TPU image)."
  type        = string
  default     = "projects/ubuntu-os-accelerator-images/global/images/family/ubuntu-accel-2404-amd64-tpu-tpu7x"
}

variable "metadata" {
  description = "Additional instance metadata key/value pairs (e.g. user-data for cloud-init)."
  type        = map(string)
  default     = {}
}

variable "startup_script" {
  description = "Optional startup script content."
  type        = string
  default     = null
}

