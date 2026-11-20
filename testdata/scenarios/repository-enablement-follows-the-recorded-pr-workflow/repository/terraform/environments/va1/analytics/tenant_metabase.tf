# Separate singleton and metadata volume; no dependency on media ClickHouse.
variable "tenant_metabase_enabled" {
  description = "Enable only after configuring DNS, credentials and BigQuery access per tenant_METABASE.md."
  type        = bool
  default     = false
}

variable "tenant_metabase_hostname" {
  type        = string
  description = "Public Metabase hostname, served by VA1 Traefik."
  default     = null
  validation {
    condition     = var.tenant_metabase_hostname == null || can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]+$", var.tenant_metabase_hostname))
    error_message = "Use a lowercase DNS hostname."
  }
}

resource "random_password" "tenant_metabase_database" {
  length  = 40
  special = false
}

resource "random_password" "tenant_metabase_encryption" {
  length  = 64
  special = false
}

resource "consul_keys" "tenant_metabase" {
  key {
    path   = "secrets/tenant/metabase/database-password"
    value  = random_password.tenant_metabase_database.result
    delete = false
  }
  key {
    path   = "secrets/tenant/metabase/encryption-secret-key"
    value  = random_password.tenant_metabase_encryption.result
    delete = false
  }
}

resource "nomad_job" "tenant_metabase" {
  count            = var.tenant_metabase_enabled ? 1 : 0
  jobspec          = file("${local.nomad_jobs_dir}/tenant-metabase.nomad.hcl")
  detach           = false
  purge_on_destroy = false
  timeouts {
    create = "30m"
    update = "30m"
  }
  hcl2 {
    vars = {
      region                     = local.nomad_region
      datacenter                 = local.nomad_datacenter
      namespace                  = nomad_namespace.tenant_analytics.name
      metabase_image             = local.analytics_images.metabase
      postgres_image             = local.analytics_images.metabase_postgres
      database_password_path     = "secrets/tenant/metabase/database-password"
      encryption_secret_key_path = "secrets/tenant/metabase/encryption-secret-key"
      public_hostname            = coalesce(var.tenant_metabase_hostname, "metabase.${data.terraform_remote_state.nodes.outputs.nomad_ingress_domain}")
    }
  }
  depends_on = [nomad_csi_volume_registration.analytics, consul_keys.tenant_metabase]
}

resource "consul_acl_policy" "tenant_analytics_tasks" {
  name  = "policy-nomad-tenant-analytics-tasks"
  rules = <<-EOT
    node_prefix "" { policy = "read" }
    service_prefix "" { policy = "read" }
    key_prefix "secrets/tenant/metabase/" { policy = "read" }
  EOT
}

resource "consul_acl_role" "tenant_analytics_tasks" {
  name     = "nomad-tenant-analytics-tasks"
  policies = [consul_acl_policy.tenant_analytics_tasks.name]
}

resource "nomad_namespace" "tenant_analytics" {
  name        = "tenant-analytics"
  description = "Isolated tenant Metabase deployment."
  meta = {
    managed_by  = "terraform"
    part_of     = "tenant"
    environment = "production"
  }
  depends_on = [consul_acl_role.tenant_analytics_tasks]
}
