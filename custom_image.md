# Custom Debian 12 OS Image Tutorial for Cloud TPU (TPU7x)

This guide walks through building a custom **Debian 12 (Bookworm)** OS image for
Cloud TPU VMs (including **TPU7x / Ironwood**, v6e, and v5p) and deploying it
end-to-end with the [Spot `2x2x2` example](./examples/spot-2x2x2).

It adapts Google Cloud's official Ubuntu LTS guide
([Use a custom OS image](https://docs.cloud.google.com/tpu/docs/custom-os-image))
for **Debian 12 (`debian-12-bookworm`)**, addressing key differences between
Ubuntu LTS and Debian 12 on Compute Engine.

---

## Important Disclaimers & Debian 12 Differences

Per [Use a custom OS image](https://docs.cloud.google.com/tpu/docs/custom-os-image):
* Google officially validates custom OS modifications against Google-supported,
  TPU-optimized Ubuntu LTS images. You are responsible for building, validating,
  and maintaining custom Debian images.
* Skip the **vBar agent** and **AI Telemetry Collector** sections if you are
  building an image for Google Kubernetes Engine (GKE), as GKE manages those
  components automatically.

### Key Differences on Debian 12 (`debian-12` GCE image family)

When adapting the Ubuntu instructions to Debian 12, pay special attention to
three differences:

1. **Debian 12 disables Intel IOMMU by default in `/etc/default/grub.d/`:**
   The standard `debian-12` Compute Engine image includes
   `/etc/default/grub.d/10_cloud_gce_intel_iommu.cfg`, which appends
   `intel_iommu=off` to `GRUB_CMDLINE_LINUX`. Because files in
   `/etc/default/grub.d/` are evaluated *after* `/etc/default/grub`, you **must**
   remove `/etc/default/grub.d/10_cloud_gce_intel_iommu.cfg` (or override it in a
   later drop-in file such as `/etc/default/grub.d/60-tpu.cfg`), otherwise TPU7x
   and v5p VFIO device binding will fail due to disabled IOMMU.
2. **Non-empty `GRUB_CMDLINE_LINUX` in `/etc/default/grub`:**
   Unlike Ubuntu where `GRUB_CMDLINE_LINUX=""` is initially empty, Debian 12
   sets serial console parameters in `GRUB_CMDLINE_LINUX`. Avoid `sed` patterns
   that match `GRUB_CMDLINE_LINUX=""`; instead append to `GRUB_CMDLINE_LINUX` in
   `/etc/default/grub.d/60-tpu.cfg`.
3. **Additional packages required:**
   While `python3` and `gcloud` CLI are pre-installed on `debian-12`, the
   boot-time metadata and container steps require `python3-yaml`,
   `python3-requests`, `docker.io`, `cloud-init`, `ethtool`, and `pciutils`.

---

## Step 1: Create a Temporary Builder VM from the Latest Debian 12 Image

Set your project, zone, and image names, and inspect the latest Debian 12 image
available in your project:

```bash
export PROJECT_ID="northam-ce-mlai-tpu"
export ZONE="us-central1-c"
export BUILDER_VM="tpu7x-debian12-builder"
export CUSTOM_IMAGE_NAME="debian-12-tpu7x-custom-v20261016"
export CUSTOM_IMAGE_FAMILY="debian-12-tpu7x"

# Verify the latest Debian 12 image visible in the project
gcloud compute images describe-from-family debian-12 \
  --project=debian-cloud \
  --format="table(name,family,architecture,status)"
```

Create a temporary Compute Engine builder VM using the latest `debian-12` image:

```bash
gcloud compute instances create "${BUILDER_VM}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --machine-type=e2-standard-4 \
  --image-project=debian-cloud \
  --image-family=debian-12 \
  --boot-disk-size=20GB \
  --boot-disk-type=pd-balanced \
  --scopes=https://www.googleapis.com/auth/cloud-platform
```

SSH into the builder VM to apply the image-creation modifications in Steps 2–6:

```bash
gcloud compute ssh "${BUILDER_VM}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}"
```

---

## Step 2: Install Prerequisites on Debian 12

Verify `python3` and `gcloud` are present, and install Docker, `cloud-init`, and
the Python libraries required by the TPU boot scripts:

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker.io \
  python3 \
  python3-yaml \
  python3-requests \
  cloud-init \
  ethtool \
  pciutils \
  curl
```

---

## Step 3: Bind TPU Devices to VFIO

To allow the guest OS to access TPU hardware directly, bind the TPU PCI devices
to the `vfio-pci` kernel driver (included in the standard Debian 12
`linux-image-cloud-amd64` kernel).

1. Create `/etc/udev/rules.d/99-tpu-vfiopci.rules`:

   ```bash
   sudo tee /etc/udev/rules.d/99-tpu-vfiopci.rules > /dev/null << 'EOF'
   # Rules for binding vfio-enabled TPU devices to vfio-pci.

   # v5e
   SUBSYSTEM=="pci", ACTION=="add", ATTRS{vendor}=="0x1ae0", ATTRS{device}=="0x0063", ATTRS{subsystem_vendor}=="0x1ae0", ATTRS{subsystem_device}=="0x00af", DRIVER!="vfio-pci", TAG+="bind_to_vfio_pci"

   # v5p
   SUBSYSTEM=="pci", ACTION=="add", ATTRS{vendor}=="0x1ae0", ATTRS{device}=="0x0062", ATTRS{subsystem_vendor}=="0x1ae0", ATTRS{subsystem_device}=="0x00ad", DRIVER!="vfio-pci", TAG+="bind_to_vfio_pci"

   # v6e
   SUBSYSTEM=="pci", ACTION=="add", ATTRS{vendor}=="0x1ae0", ATTRS{device}=="0x006f", ATTRS{subsystem_vendor}=="0x1ae0", ATTRS{subsystem_device}=="0x00d1", DRIVER!="vfio-pci", TAG+="bind_to_vfio_pci"

   # TPU7x
   SUBSYSTEM=="pci", ACTION=="add", ATTRS{vendor}=="0x1ae0", ATTRS{device}=="0x0076", ATTRS{subsystem_vendor}=="0x1ae0", ATTRS{subsystem_device}=="0x00f2", DRIVER!="vfio-pci", TAG+="bind_to_vfio_pci"

   # Bind all 'bind_to_vfio_pci' tagged devices to vfio-pci.
   TAG=="bind_to_vfio_pci", RUN+="/lib/udev/bind_to_vfio_pci.sh $kernel"
   EOF
   ```

2. Create `/lib/udev/bind_to_vfio_pci.sh` and make it executable:

   ```bash
   sudo tee /lib/udev/bind_to_vfio_pci.sh > /dev/null << 'EOF'
   #!/bin/bash
   #!/usr/bin/env bash

   # Run ./bind_to_vfio_pci.sh <DBDF>
   # Binds the device at <DBDF> to vfio-pci.
   # If the device is already bound to a driver, unbinds it first.

   # Load the vfio-pci module into the kernel. No-op if already loaded.
   modprobe vfio-pci

   DBDF_REGEX="^[[:xdigit:]]{4}:[[:xdigit:]]{2}:[[:xdigit:]]{2}.[[:xdigit:]]$"

   unset BDF
   if [[ $1 =~ $DBDF_REGEX ]]; then
       BDF=$1
   else
       echo "Error: BDF arg ($1) is not in form dddd:bb:dd.f"
       exit 1
   fi

   PCI_PATH="/sys/bus/pci/devices/$BDF"

   echo "vfio-pci" > "$PCI_PATH/driver_override"

   PCI_DRIVER_PATH="$PCI_PATH/driver"
   if [[ -d "$PCI_DRIVER_PATH" ]]; then
       curr_driver=$(readlink "$PCI_DRIVER_PATH")
       curr_driver=${curr_driver##*/}
       if [[ $curr_driver == "vfio-pci" ]]; then
           echo "$BDF already bound to vfio-pci"
           exit 0
       else
           echo "$BDF" > "$PCI_DRIVER_PATH/unbind"
           if [[ -d "$PCI_DRIVER_PATH" ]]; then
               echo "Error: Unable to unbind $PCI_DRIVER_PATH"
               exit 1
           fi
           echo "Unbound $BDF from driver $curr_driver"
       fi
   fi
   echo "$BDF" > /sys/bus/pci/drivers_probe
   echo "Bound $BDF to vfio-pci"

   # Grant read/write access on VFIO device to all users
   IOMMU_GROUP=$(readlink "$PCI_PATH/iommu_group" | xargs basename)
   VFIO_DEV="/dev/vfio/$IOMMU_GROUP"
   if [[ -c "$VFIO_DEV" ]]; then
       chmod 0666 "$VFIO_DEV"
   else
       echo "$VFIO_DEV not found"
       exit 1
   fi

   # Set allow_unsafe_interrupts for x86 platforms.
   (uname -a | grep -q x86_64) && echo 1 > /sys/module/vfio_iommu_type1/parameters/allow_unsafe_interrupts

   # This is only needed to avoid non-zero exit code from previous command.
   echo "All Done!"
   EOF

   sudo chmod +x /lib/udev/bind_to_vfio_pci.sh
   ```

3. Grant all users access to `/dev/accel*` TPU devices:

   ```bash
   echo 'KERNEL=="accel*" MODE="0666"' | sudo tee /etc/udev/rules.d/99-tpu.rules
   ```

---

## Step 4: Modify the Image to Enhance Performance

### Memory and Open File Limits

Allow processes to lock unlimited memory (`memlock`) and increase open file
descriptor limits (`nofile`) to `100000`:

```bash
sudo tee /etc/security/limits.d/99-tpu.conf > /dev/null << 'EOF'
*    hard    memlock      unlimited
*    soft    memlock      unlimited
*    soft    nofile       100000
*    hard    nofile       100000
root soft    nofile       100000
root hard    nofile       100000
EOF

sudo tee -a /etc/security/limits.conf > /dev/null << 'EOF'
*  hard  memlock  unlimited
*  soft  memlock  unlimited
*    soft    nofile       100000
*    hard    nofile       100000
root soft    nofile       100000
root hard    nofile       100000
EOF
```

### Kernel Parameters (GRUB Configuration on Debian 12)

Configure the required kernel parameters:
* `idle=poll`: Prevents the CPU from entering low-power idle states.
* `intel_iommu=on,sm_on`: Enables Intel IOMMU in scalable mode (required for
  TPU7x and v5p).
* `iommu.passthrough=0`: Disables IOMMU passthrough so VFIO DMA mapping works
  reliably.
* `transparent_hugepage=always`: Enables Transparent Huge Pages (THP).

On Debian 12, first remove `/etc/default/grub.d/10_cloud_gce_intel_iommu.cfg`
(which otherwise forces `intel_iommu=off`), create `/etc/default/grub.d/60-tpu.cfg`,
and regenerate `/boot/grub/grub.cfg`:

```bash
sudo rm -f /etc/default/grub.d/10_cloud_gce_intel_iommu.cfg

sudo tee /etc/default/grub.d/60-tpu.cfg > /dev/null << 'EOF'
# TPU kernel parameters for Debian 12
GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX idle=poll intel_iommu=on,sm_on iommu.passthrough=0 transparent_hugepage=always"
EOF

sudo update-grub

# Verify the generated kernel command line in /boot/grub/grub.cfg
sudo grep "linux.*vmlinuz" /boot/grub/grub.cfg
```

---

## Step 5: Install vBar Agent and Optional AI Telemetry Collector

The **vBar control agent** is required on non-GKE TPU VMs for the inter-chip
interconnect (ICI) network to function.

1. Authenticate Docker and pull the `vbar_control_agent` and
   `ai-telemetry-collector` images:

   ```bash
   sudo gcloud auth configure-docker gcr.io,us-docker.pkg.dev --quiet
   sudo docker pull gcr.io/cloud-tpu-v2-images/vbar_control_agent:0.0.1
   sudo docker pull gcr.io/cloud-tpu-v2-images/ai-telemetry-collector:latest
   ```

2. Extract the statically linked `vbar_control_agent` binary into
   `/usr/local/bin/vbar_control_agent` (and symlink `/usr/bin/vbar_control_agent`)
   so it can be invoked directly at boot time as a systemd service or via
   `cloud-init`:

   ```bash
   cid=$(sudo docker create gcr.io/cloud-tpu-v2-images/vbar_control_agent:0.0.1)
   sudo docker cp "${cid}:/vbar_control_agent_files/bin/vbar_control_agent" /usr/local/bin/vbar_control_agent
   sudo docker rm "${cid}"
   sudo chmod +x /usr/local/bin/vbar_control_agent
   sudo ln -sf /usr/local/bin/vbar_control_agent /usr/bin/vbar_control_agent
   ```

   *(Alternatively, you can run `vbar_control_agent` inside a privileged host-networked container using `/vbar_control_agent_files/bin/vbar_control_agent` as the entrypoint.)*

---

## Step 6: Configure Boot-Time Modifications

Every time a TPU VM boots, it must:
1. Retrieve `tpu-env` runtime attributes from the Compute Engine metadata server
   and write them to `/home/tpu-runtime/tpu-env`
   (`/var/scripts/configure-env-vars.sh`).
2. Provide `/var/scripts/get-vm-metadata.py` for querying instance metadata.
3. Configure Cloud Storage timeout variables in `/etc/environment`
   (`/var/scripts/configure-gcs-timeouts.sh`).
4. Start the `vbar_control_agent` daemon.

You can either **bake these scripts and systemd services directly into the
image** (recommended so every VM works out-of-the-box without requiring extra
instance metadata) **or** pass them at boot via `cloud-init` (`user-data`
metadata).

### Option A (Recommended): Bake Scripts & Systemd Units into the Image

Run the following on the builder VM:

```bash
sudo mkdir -p /var/scripts /home/tpu-runtime

# 1. /var/scripts/configure-env-vars.sh
sudo tee /var/scripts/configure-env-vars.sh > /dev/null << 'EOF'
#!/bin/bash
grep -q CLOUDSDK_PYTHON /etc/environment || echo "CLOUDSDK_PYTHON=/usr/bin/python3" >> /etc/environment

export HOME=/home/tpu-runtime
mkdir -p "${HOME}"
curl -s 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/tpu-env' -H 'Metadata-Flavor: Google' > /tmp/tpu-env.yaml

eval $(python3 -c '''
import yaml
stream_in=open("/tmp/tpu-env.yaml", "r")
data = yaml.safe_load(stream_in)
if isinstance(data, dict):
  for k,v in data.items():
    print("{var}=\"{value}\"".format(var = k, value = str(v)))
''' > "${HOME}/tpu-env"
)

rm -f "/tmp/tpu-env.yaml"

printenv
cat "${HOME}/tpu-env"
EOF
sudo chmod 0755 /var/scripts/configure-env-vars.sh

# 2. /var/scripts/get-vm-metadata.py
sudo tee /var/scripts/get-vm-metadata.py > /dev/null << 'EOF'
#!/usr/bin/env python3
import sys, requests, os

if len(sys.argv) < 2:
  sys.stderr.write('Must provide key')
  os._exit(1)

key = sys.argv[1]
default = None
if len(sys.argv) > 2:
  default = sys.argv[2]

attribute_type = 'attributes'
if len(sys.argv) > 3:
  attribute_type = sys.argv[3]

request = requests.get("http://metadata.google.internal/computeMetadata/v1/instance/{}/{}".format(attribute_type, key), headers={'Metadata-Flavor': 'Google'})
if request.status_code == 200:
  print(request.content)
elif request.status_code == 404 or request.status_code == '403':
  sys.stderr.write('Metadata key: {} does not exist\n'.format(key))
  if default:
    print(default)
else:
  sys.stderr.write('Lookup failed with: {}'.format(request))
EOF
sudo chmod 0755 /var/scripts/get-vm-metadata.py

# 3. /var/scripts/configure-gcs-timeouts.sh
sudo tee /var/scripts/configure-gcs-timeouts.sh > /dev/null << 'EOF'
#!/bin/bash
grep -q GCS_RESOLVE_REFRESH_SECS /etc/environment || {
  echo "GCS_RESOLVE_REFRESH_SECS=60" >> /etc/environment
  echo "GCS_REQUEST_CONNECTION_TIMEOUT_SECS=300" >> /etc/environment
  echo "GCS_METADATA_REQUEST_TIMEOUT_SECS=300" >> /etc/environment
  echo "GCS_READ_REQUEST_TIMEOUT_SECS=300" >> /etc/environment
  echo "GCS_WRITE_REQUEST_TIMEOUT_SECS=600" >> /etc/environment
}
EOF
sudo chmod 0755 /var/scripts/configure-gcs-timeouts.sh
sudo /var/scripts/configure-gcs-timeouts.sh

# 4. Systemd services for boot-time execution
sudo tee /etc/systemd/system/tpu-env-setup.service > /dev/null << 'EOF'
[Unit]
Description=Configure Cloud TPU environment variables and GCS timeouts
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/var/scripts/configure-gcs-timeouts.sh
ExecStart=/var/scripts/configure-env-vars.sh

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/vbar-control-agent.service > /dev/null << 'EOF'
[Unit]
Description=Cloud TPU vBar Control Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/environment
ExecStart=/usr/local/bin/vbar_control_agent --logtostderr --gid= --uid= --chroot= --census_enabled=false --loas_pwd_fallback_in_corp
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable tpu-env-setup.service vbar-control-agent.service
sudo cloud-init clean --logs
```

### Option B: Pass Boot-Time Modifications via `cloud-init` (`user-data`)

If you prefer using `cloud-init` via instance metadata (`metadata = { user-data = ... }`),
use the following `#cloud-config` payload:

```yaml
#cloud-config
write_files:
  - path: /var/scripts/configure-env-vars.sh
    permissions: '0755'
    owner: root
    content: |
      #!/bin/bash
      grep -q CLOUDSDK_PYTHON /etc/environment || echo "CLOUDSDK_PYTHON=/usr/bin/python3" >> /etc/environment

      export HOME=/home/tpu-runtime
      mkdir -p "${HOME}"
      curl -s 'http://metadata.google.internal/computeMetadata/v1/instance/attributes/tpu-env' -H 'Metadata-Flavor: Google' > /tmp/tpu-env.yaml

      eval $(python3 -c '''
      import yaml
      stream_in=open("/tmp/tpu-env.yaml", "r")
      for k,v in yaml.safe_load(stream_in).items():
        print("{var}=\"{value}\"".format(var = k, value = str(v)))
      ''' > "${HOME}/tpu-env"
      )

      rm -f "/tmp/tpu-env.yaml"

      printenv
      cat ${HOME}/tpu-env

  - path: /var/scripts/get-vm-metadata.py
    permissions: '0755'
    owner: root
    content: |
      import sys, requests, os

      if len(sys.argv) < 2:
        sys.stderr.write('Must provide key')
        os._exit(1)

      key = sys.argv[1]
      default = None
      if len(sys.argv) > 2:
        default = sys.argv[2]

      attribute_type = 'attributes'
      if len(sys.argv) > 3:
        attribute_type = sys.argv[3]

      request = requests.get("http://metadata.google.internal/computeMetadata/v1/instance/{}/{}".format(attribute_type, key), headers={'Metadata-Flavor': 'Google'})
      if request.status_code == 200:
        print(request.content)
      elif request.status_code == 404 or request.status_code == '403':
        sys.stderr.write('Metadata key: {} does not exist\n'.format(key))
        if default:
          print(default)
      else:
        sys.stderr.write('Lookup failed with: {}'.format(request))

  - path: /var/scripts/configure-gcs-timeouts.sh
    permissions: '0755'
    owner: root
    content: |
      #!/bin/bash
      echo "GCS_RESOLVE_REFRESH_SECS=60" >> /etc/environment
      echo "GCS_REQUEST_CONNECTION_TIMEOUT_SECS=300" >> /etc/environment
      echo "GCS_METADATA_REQUEST_TIMEOUT_SECS=300" >> /etc/environment
      echo "GCS_READ_REQUEST_TIMEOUT_SECS=300" >> /etc/environment
      echo "GCS_WRITE_REQUEST_TIMEOUT_SECS=600" >> /etc/environment

runcmd:
  - [ bash, /var/scripts/configure-gcs-timeouts.sh ]
  - [ bash, /var/scripts/configure-env-vars.sh ]
  - [ bash, -c, "nohup vbar_control_agent --logtostderr --gid= --uid= --chroot= --census_enabled=false --loas_pwd_fallback_in_corp >/var/log/vbar_control_agent.log 2>&1 &" ]
```

---

## Step 7: Create the Custom Debian 12 OS Image

Exit the builder VM SSH session, stop the builder instance, create the custom
image in your project, and delete the temporary builder VM:

```bash
# Stop the builder VM
gcloud compute instances stop "${BUILDER_VM}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}"

# Create the custom OS image from the builder VM's boot disk
gcloud compute images create "${CUSTOM_IMAGE_NAME}" \
  --project="${PROJECT_ID}" \
  --source-disk="${BUILDER_VM}" \
  --source-disk-zone="${ZONE}" \
  --family="${CUSTOM_IMAGE_FAMILY}" \
  --description="Custom Debian 12 (bookworm) OS image configured for Cloud TPU (TPU7x/v6e/v5p)"

# Delete the temporary builder VM
gcloud compute instances delete "${BUILDER_VM}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --quiet
```

---

## Step 8: End-to-End Test with the Spot `2x2x2` Example

Deploy a `2x2x2` TPU7x slice (8 chips, 2 hosts) on Spot VMs using the custom
Debian 12 image via [`examples/spot-2x2x2`](./examples/spot-2x2x2):

```bash
cd examples/spot-2x2x2
terraform init

terraform apply \
  -var project_id="${PROJECT_ID}" \
  -var zone="${ZONE}" \
  -var name="tpu7x-spot-deb12" \
  -var source_image="projects/${PROJECT_ID}/global/images/family/${CUSTOM_IMAGE_FAMILY}"
```

Verify the TPU7x hosts are running Debian 12 with VFIO devices bound, kernel
parameters active, `tpu-env` populated, and `vbar_control_agent` running:

```bash
# List the MIG instances
gcloud compute instance-groups managed list-instances tpu7x-spot-deb12 \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}"

# SSH into one of the TPU7x hosts to verify the custom Debian 12 image
INSTANCE_NAME=$(gcloud compute instance-groups managed list-instances tpu7x-spot-deb12 \
  --project="${PROJECT_ID}" --zone="${ZONE}" --format="value(instance.basename())" | head -n 1)

gcloud compute ssh "${INSTANCE_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --command="
    grep PRETTY_NAME /etc/os-release &&
    cat /proc/cmdline &&
    ls -l /dev/vfio/ &&
    lspci -nnk -d 1ae0:0076 &&
    systemctl is-active vbar-control-agent.service &&
    head -n 20 /home/tpu-runtime/tpu-env
  "
```

When finished testing, tear down the Spot slice:

```bash
terraform destroy \
  -var project_id="${PROJECT_ID}" \
  -var zone="${ZONE}" \
  -var name="tpu7x-spot-deb12" \
  -var source_image="projects/${PROJECT_ID}/global/images/family/${CUSTOM_IMAGE_FAMILY}"
```

### Using with DWS Calendar Reservations (`examples/calendar-reservation`)

You can also pass `source_image` (along with optional `boot_disk_size_gb`,
`metadata`, and `startup_script`) to [`examples/calendar-reservation`](./examples/calendar-reservation):

```bash
cd examples/calendar-reservation
terraform init

# Phase 1 (before start_time): pre-create the MIG at size 0
terraform apply \
  -var project_id="${PROJECT_ID}" \
  -var zone="${ZONE}" \
  -var topology="4x4x4" \
  -var reservation_name="${RESERVATION_NAME}" \
  -var source_image="projects/${PROJECT_ID}/global/images/family/${CUSTOM_IMAGE_FAMILY}"

# Phase 2 (once the reservation window opens): scale up the slice
terraform apply \
  -var project_id="${PROJECT_ID}" \
  -var zone="${ZONE}" \
  -var topology="4x4x4" \
  -var reservation_name="${RESERVATION_NAME}" \
  -var source_image="projects/${PROJECT_ID}/global/images/family/${CUSTOM_IMAGE_FAMILY}" \
  -var activate_slice=true
```

