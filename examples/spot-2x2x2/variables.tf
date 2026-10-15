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

variable "wait_for_instances" {
  description = "Wait for the MIG to become STABLE during apply."
  type        = bool
  default     = true
}
