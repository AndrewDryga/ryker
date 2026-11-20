variable "RYKER_VERSION" {}
variable "RYKER_IMAGE_REPOSITORY" {
  default = "ghcr.io/andrewdryga/ryker"
}

group "default" {
  targets = ["controller", "worker-vm"]
}

target "controller" {
  platforms = ["linux/amd64"]
  args = { RYKER_VERSION = RYKER_VERSION }
  tags = ["${RYKER_IMAGE_REPOSITORY}:${RYKER_VERSION}"]
}

target "coop" {
  dockerfile = "deploy/compose/coop/Dockerfile"
  platforms = ["linux/amd64"]
}

target "worker-vm" {
  dockerfile = "deploy/worker-vm/Dockerfile"
  contexts = { coop-image = "target:coop" }
  platforms = ["linux/amd64"]
  tags = ["${RYKER_IMAGE_REPOSITORY}-worker-vm:${RYKER_VERSION}"]
}
