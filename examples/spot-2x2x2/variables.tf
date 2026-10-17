variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "zone" {
  description = "Zone with TPU7x capacity (e.g. us-central1-c, us-central1-b, us-east1-b, us-east5-a)."
  type        = string
  default     = "us-central1-c"
}

variable "name" {
  description = "Base name for the slice resources."
  type        = string
  default     = "tpu7x-spot-2x2x2"
}

variable "topology" {
  description = "TPU7x topology to test."
  type        = string
  default     = "2x2x2"
}

variable "instance_termination_action" {
  description = "Spot preemption action: STOP (default per docs) or DELETE."
  type        = string
  default     = "STOP"
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

variable "wait_for_instances" {
  description = "Wait for the MIG to become STABLE during apply."
  type        = bool
  default     = true
}

