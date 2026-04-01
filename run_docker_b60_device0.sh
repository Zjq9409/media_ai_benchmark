MOUNT_DIR_DATA="$(pwd)"

docker run -idt -u root --name dl_benchmark_b60_device0 \
--device=/dev/dri/renderD128  \
--net=host \
-v "${MOUNT_DIR_DATA}":/home/dlstreamer/work \
intel/dlstreamer:2025.2.0-ubuntu24 /bin/bash
