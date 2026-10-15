output "slice" {
  description = "Reservation-bound slice summary."
  value = {
    reservation_name   = var.reservation_name
    topology           = module.tpu_slice.topology
    chip_count         = module.tpu_slice.chip_count
    vm_count           = module.tpu_slice.vm_count
    target_size        = module.tpu_slice.target_size
    provisioning_model = module.tpu_slice.provisioning_model
    zone               = module.tpu_slice.location
    mig_name           = module.tpu_slice.mig_name
    list_instances     = module.tpu_slice.list_instances_command
  }
}
