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
  description = "TPU7x slice topology, e.g. 2x2x2 (8 chips), 4x4x4 (64 chips), 8x8x8 (512 chips). Must fit in the reservation."
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
