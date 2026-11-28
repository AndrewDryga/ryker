# Build with the linux/amd64 worker image built from the same Ryker checkout as the controller.
FROM coop-image AS worker
FROM docker:29.10.0-dind-alpine3.24@sha256:4bbc7223f81db790097c6dea42fb93e05b8fead4f0431fbe6ccaba6e8473201c AS daemon
FROM debian:bookworm-20261104-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl genisoimage netcat-openbsd python3 qemu-system-x86 qemu-utils seabios \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/worker
RUN curl --fail --location --retry 3 --output debian.qcow2 \
    https://cloud.debian.org/images/cloud/bookworm/20261117-2665/debian-12-generic-amd64-20261117-2665.qcow2 \
    && echo 'd597a8b422a0fa7f7cf1a0477d23be7f7514f32e57ccb8d0c69156e1be4a7e1712fb64aee6298520d70aa573b801d0cfe3392ab5de39829728760c0cf99ef4ec  debian.qcow2' | sha512sum -c -
COPY --from=worker /usr/local/bin/coop payload/coop
COPY --from=worker /usr/local/bin/docker payload/docker
COPY --from=worker /usr/libexec/docker/cli-plugins/docker-buildx payload/docker-buildx
COPY --from=worker /usr/libexec/docker/cli-plugins/docker-compose payload/docker-compose
COPY --from=worker /usr/local/share/ryker/Box.Dockerfile payload/Box.Dockerfile
COPY --from=daemon /usr/local/bin/dockerd /usr/local/bin/containerd-shim-runc-v2 /usr/local/bin/runc /usr/local/bin/docker-init /usr/local/bin/docker-proxy payload/engine/
COPY deploy/worker-vm/guest/ payload/
RUN genisoimage -quiet -J -r -V COOPTOOLS -o tools.iso payload && rm -rf payload
COPY deploy/worker-vm/launch.py deploy/worker-vm/user-data ./
USER 1000:993
ENTRYPOINT ["python3", "/opt/worker/launch.py"]
