output "slice" {
  description = "Summary of the provisioned slice."
  value = {
    topology           = module.tpu_slice.topology
    chip_count         = module.tpu_slice.chip_count
    vm_count           = module.tpu_slice.vm_count
    machine_type       = module.tpu_slice.machine_type
    provisioning_model = module.tpu_slice.provisioning_model
    zone               = module.tpu_slice.location
    mig_name           = module.tpu_slice.mig_name
    instance_template  = module.tpu_slice.instance_template_name
    workload_policy    = module.tpu_slice.workload_policy_self_link
    data_disk_count    = module.tpu_slice.data_disk_count
    data_disk_size_gb  = module.tpu_slice.data_disk_size_gb
  }
}

output "list_instances_command" {
  description = "Run this to see the hosts of the slice."
  value       = module.tpu_slice.list_instances_command
}
