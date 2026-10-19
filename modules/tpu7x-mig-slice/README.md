# `tpu7x-mig-slice`

Provisions a **multi-host TPU7x (Ironwood) slice** on Compute Engine as a managed
instance group (MIG), following
[Create a MIG with multi-host TPU slice](https://docs.cloud.google.com/compute/docs/tpus/create-tpu-mig-multi-host-slice).

```
topology "4x4x4"  ──►  64 chips / 4 chips per host  ──►  MIG target size 16 × tpu7x-standard-4t
```

The module creates exactly the three objects the doc prescribes:

| # | Resource | Key settings |
|---|----------|--------------|
| 1 | `google_compute_instance_template` | `tpu7x-standard-4t`, TPU7x Ubuntu image, Hyperdisk Balanced boot, gVNIC, `onHostMaintenance=TERMINATE`, scheduling block per consumption option |
| 2 | `google_compute_resource_policy` (workload policy) | `type=HIGH_THROUGHPUT`, `acceleratorTopology=<topology>` → VMs form **one** ICI-connected slice |
| 3 | `google_compute_instance_group_manager` *or* `…_region_instance_group_manager` | `targetSizePolicy.mode=BULK`, `defaultActionOnFailure=DO_NOTHING`, workload policy attached; regional MIGs use `ANY_SINGLE_ZONE` + `instanceRedistributionType=NONE` |

## Usage

```hcl
module "slice" {
  source = "../../modules/tpu7x-mig-slice"

  project_id = "my-project"
  name       = "ironwood-train"
  zone       = "us-central1-c"

  topology           = "4x4x4"          # any TPU7x multi-host shape
  provisioning_model = "RESERVATION_BOUND"
  reservation_name   = "my-calendar-res" # auto-created reservation of a DWS calendar request

  network    = "my-vpc"
  subnetwork = "my-subnet"
}
```

### Consumption options (`provisioning_model`)

| Value | What the template sets | Extra inputs |
|-------|------------------------|--------------|
| `STANDARD` | on-demand; optional `reservation_affinity` when `reservation_name` is given | – |
| `SPOT` | `provisioningModel=SPOT`, `preemptible=true`, `automaticRestart=false`, `instanceTerminationAction=STOP` | `instance_termination_action` (STOP/DELETE), optional `max_run_duration_seconds` |
| `RESERVATION_BOUND` | `provisioningModel=RESERVATION_BOUND`, `instanceTerminationAction=DELETE`, `SPECIFIC_RESERVATION` affinity | **`reservation_name`** (may be `RES/reservationBlocks/BLOCK[/reservationSubBlocks/SUB]` for All-Capacity-mode reservations) |
| `FLEX_START` | `provisioningModel=FLEX_START`, `instanceTerminationAction=DELETE`, `maxRunDuration` | **`max_run_duration_seconds`** |

### Supported TPU7x topologies

All TPU7x shapes use the 4-chip `tpu7x-standard-4t` host (224 vCPU, 960 GB RAM, 2 NUMA nodes).

| Topology | Chips | Hosts / VMs | Cubes |
|----------|------:|------------:|------:|
| 2x2x1 | 4 | 1 | 1/16 |
| 2x2x2 | 8 | 2 | 1/8 |
| 2x2x4 | 16 | 4 | 1/4 |
| 2x4x4 | 32 | 8 | 1/2 |
| 4x4x4 | 64 | 16 | 1 |
| 4x4x8 | 128 | 32 | 2 |
| 4x8x8 | 256 | 64 | 4 |
| 8x8x8 | 512 | 128 | 8 |
| 8x8x16 | 1024 | 256 | 16 |
| 8x16x16 | 2048 | 512 | 32 |

Any `AxBxC` whose product is a multiple of 4 and ≥ 4 passes module validation;
the API rejects shapes TPU7x does not support.

### Zonal vs regional MIG

* `mig_type = "zonal"` (default) — requires `zone`. The workload policy is created in the zone's region.
* `mig_type = "regional"` — requires `region`; optional `regional_zones` to restrict placement.
  The MIG converges to `ANY_SINGLE_ZONE` so the whole slice lands in one zone.

### Using an existing DWS calendar-mode future reservation

Terraform does not create the future reservation (the native provider resource does not
yet accept the TPU7x VM family); create/approve it with the console or
`gcloud compute future-reservations create … --reservation-mode=CALENDAR --tpu-version=TPU7X --chip-count=N`.
When Google approves the request, Compute Engine auto-creates a reservation whose name
is the request's `reservationName` (defaults to the request name):

```bash
gcloud compute future-reservations describe FR_NAME --zone ZONE \
  --format='value(reservationName,status.procurementStatus,timeWindow.startTime,timeWindow.endTime)'
```

Bind the slice to it with `provisioning_model = "RESERVATION_BOUND"` and
`reservation_name = <that name>` (zone must match; for shared reservations use
`projects/OWNER/reservations/NAME`). Before `startTime` the reservation has 0 capacity
and VM creation fails, so create the MIG with `target_size_override = 0` and switch to
`null` (full size) once the window opens. At `endTime` the reservation is deleted and the
hosts are `DELETE`d (the module's default `instance_termination_action` for this model).


## Notes & gotchas

* **Quota** — on-demand/Spot/flex-start need TPU7x quota in the region
  (e.g. `PREEMPTIBLE-TPU7X-per-project-zone`). Reservation-bound VMs need none.
* **Custom-mode VPCs** must pass `subnetwork`.
* `wait_for_instances = true` makes `apply` block until the MIG is `STABLE`
  (all hosts RUNNING). With Spot/flex-start this can hit the configured timeout
  if there is no capacity; the MIG keeps retrying in the background.
* The template uses `name_prefix` + `create_before_destroy`, so changing template
  inputs creates a new template and points the MIG at it. Because a slice must be
  recreated as a whole, trigger the roll yourself:
  `gcloud compute instance-groups managed rolling-action replace MIG --max-unavailable=100% …`
  or scale to 0 and back.
* TensorFlow is not supported on TPU7x; use JAX or PyTorch.

## Troubleshooting a slice that stays in `CREATING`

A multi-host slice is created atomically (`BULK`): the MIG submits one
`compute.queuedResources.insert` for all hosts and retries until it succeeds.
Progress and errors are reported on the MIG, not on individual VMs:

```bash
gcloud compute instance-groups managed describe MIG --zone ZONE \
  --format="yaml(status.isStable,status.appliedAcceleratorTopologies,status.bulkInstanceOperation)"
```

| `bulkInstanceOperation.lastProgressCheck.error` | Meaning | Action |
|---|---|---|
| `ZONE_RESOURCE_POOL_EXHAUSTED_WITH_DETAILS` / `INSUFFICIENT_CAPACITY` / `VM_MIN_COUNT_NOT_REACHED` | No (Spot / on-demand) TPU7x capacity in the zone right now | Wait (the MIG retries), try another TPU7x zone, or use a DWS calendar / flex-start reservation |
| `QUOTA_EXCEEDED … TPUS_PER_TPU_FAMILY` | No TPU7x quota in that region | Request `TPU7X` / `PREEMPTIBLE-TPU7X` quota or switch region |
| `appliedAcceleratorTopologies[].state = ACTIVATING` | Normal while hosts are being provisioned; becomes `ACTIVE` once the ICI slice is up | – |

`gcloud compute operations list --filter="targetLink~MIG" --sort-by=~insertTime`
shows the underlying `queuedResources.insert` operations and their error codes.


<!-- BEGIN_TF_DOCS -->
## Inputs (summary)

| Name | Type | Default | Description |
|------|------|---------|-------------|
| `project_id` | string | – | Project |
| `name` | string | – | Base name (RFC1035, ≤ 40 chars) |
| `zone` / `region` | string | `null` | Placement (zone for zonal, region for regional) |
| `mig_type` | string | `"zonal"` | `zonal` or `regional` |
| `topology` | string | – | e.g. `"2x2x2"` |
| `machine_type` | string | `"tpu7x-standard-4t"` | 4-chip host type |
| `provisioning_model` | string | `"STANDARD"` | `STANDARD` / `SPOT` / `RESERVATION_BOUND` / `FLEX_START` |
| `reservation_name` | string | `null` | Reservation to target |
| `instance_termination_action` | string | `null` (auto) | `STOP` / `DELETE` |
| `max_run_duration_seconds` | number | `null` | Required for `FLEX_START` |
| `source_image` | string | TPU7x Ubuntu 24.04 family | Boot image |
| `boot_disk_type` / `boot_disk_size_gb` | string / number | `hyperdisk-balanced` / `100` | Boot disk |
| `data_disk_count` | number | `0` | Number of non-boot read-write Hyperdisk Balanced disks per VM (`0`–`63`) |
| `data_disk_type` / `data_disk_size_gb` | string / number | `hyperdisk-balanced` / `500` | Non-boot per-VM data disk type & size (GiB) |
| `data_disk_provisioned_iops` / `data_disk_provisioned_throughput` | number | `null` | Optional provisioned IOPS / throughput (MiB/s) per non-boot data disk |
| `data_disk_auto_delete` | bool | `true` | Auto-delete non-boot data disks with the VM |
| `network` / `subnetwork` / `subnetwork_project` | string | `"default"` / `null` / `null` | Networking |
| `nic_type` | string | `"GVNIC"` | vNIC type |
| `enable_external_ip` | bool | `false` | External IP per host |
| `network_tags`, `labels`, `metadata`, `startup_script` | – | – | Passthrough |
| `service_account_email` / `service_account_scopes` | – | default SA / `cloud-platform` | Identity |
| `enable_oslogin` | bool | `true` | Sets `enable-oslogin=TRUE` |
| `default_action_on_failure` | string | `"DO_NOTHING"` | MIG lifecycle policy |
| `target_size_override` | number | `null` | `0` to pre-create an empty MIG |
| `wait_for_instances` | bool | `false` | Block until STABLE |
| `mig_timeouts` | object | 30m each | Create/update/delete timeouts |

## Outputs

`topology`, `chip_count`, `vm_count`, `target_size`, `machine_type`, `provisioning_model`,
`instance_template_self_link`, `instance_template_name`, `workload_policy_self_link`,
`mig_name`, `mig_self_link`, `instance_group`, `mig_type`, `location`, `list_instances_command`,
`data_disk_count`, `data_disk_size_gb`.
<!-- END_TF_DOCS -->
