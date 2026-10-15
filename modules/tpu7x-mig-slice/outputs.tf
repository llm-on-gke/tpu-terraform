#------------------------------------------------------------------------------
# tpu7x-mig-slice — outputs
#------------------------------------------------------------------------------

locals {
  mig = local.is_zonal ? google_compute_instance_group_manager.zonal[0] : google_compute_region_instance_group_manager.regional[0]

  list_instances_cmd = (
    local.is_zonal
    ? "gcloud compute instance-groups managed list-instances ${var.name} --project=${var.project_id} --zone=${var.zone}"
    : "gcloud compute instance-groups managed list-instances ${var.name} --project=${var.project_id} --region=${var.region}"
  )
}

output "topology" {
  description = "TPU slice topology."
  value       = var.topology
}

output "chip_count" {
  description = "Total TPU chips in the slice."
  value       = local.chips
}

output "vm_count" {
  description = "Number of host VMs in the slice (MIG target size unless overridden)."
  value       = local.vm_count
}

output "target_size" {
  description = "Effective MIG target size."
  value       = local.target_size
}

output "machine_type" {
  description = "Machine type used for the TPU hosts."
  value       = var.machine_type
}

output "provisioning_model" {
  description = "Provisioning model used by the slice."
  value       = var.provisioning_model
}

output "instance_template_self_link" {
  description = "Self link of the instance template."
  value       = google_compute_instance_template.tpu.self_link
}

output "instance_template_name" {
  description = "Name of the instance template."
  value       = google_compute_instance_template.tpu.name
}

output "workload_policy_self_link" {
  description = "Self link of the HIGH_THROUGHPUT workload policy."
  value       = google_compute_resource_policy.workload.self_link
}

output "mig_name" {
  description = "Name of the managed instance group."
  value       = local.mig.name
}

output "mig_self_link" {
  description = "Self link of the managed instance group."
  value       = local.mig.self_link
}

output "instance_group" {
  description = "URL of the underlying instance group."
  value       = local.mig.instance_group
}

output "mig_type" {
  description = "zonal or regional."
  value       = var.mig_type
}

output "location" {
  description = "Zone (zonal MIG) or region (regional MIG) of the slice."
  value       = local.is_zonal ? var.zone : var.region
}

output "list_instances_command" {
  description = "gcloud command that lists the slice's VMs and their current actions."
  value       = local.list_instances_cmd
}
