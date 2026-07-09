#!/bin/bash
set -e

MOUNT_DIR_DATA="$(pwd)"
IMAGE_NAME="intel/dlstreamer:2026.1.0-ubuntu24"
CONTAINER_NAME="dl_benchmark_b60_2026"

# Check if image exists locally
if ! docker image inspect "${IMAGE_NAME}" > /dev/null 2>&1; then
    echo "Image ${IMAGE_NAME} not found locally. Pulling from registry..."
    docker pull "${IMAGE_NAME}"
else
    echo "Image ${IMAGE_NAME} found locally."
fi

# Stop and remove existing container if it exists
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Removing existing container ${CONTAINER_NAME}..."
    docker stop "${CONTAINER_NAME}" 2>/dev/null || true
    docker rm "${CONTAINER_NAME}" 2>/dev/null || true
fi

echo "Starting container ${CONTAINER_NAME}..."
docker run -idt -u root --name "${CONTAINER_NAME}" \
--device=/dev/dri/renderD128  \
--net=host \
-v "${MOUNT_DIR_DATA}":/home/dlstreamer/work \
"${IMAGE_NAME}" /bin/bash

echo "✓ Container ${CONTAINER_NAME} started successfully"
echo "To enter the container, run: docker exec -it ${CONTAINER_NAME} bash"
