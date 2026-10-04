# Infrastructure

Everything the arena and website services run on in VA1.

- **Compute:** a Nomad cluster with Consul service discovery (`nomad/`).
- **Datastores:** PostgreSQL with pgBackRest backups, Cassandra with Medusa backups, ClickHouse and Metabase.
- **Monitoring:** VictoriaMetrics and VictoriaLogs; Grafana alerting with rules generated from `observability/alerts/`.
- **Edge:** Bunny CDN pull zones for `arena` and `website`; DNS at Cloudflare.
- **Uptime:** Better Stack monitors for the public endpoints.
- **Storage:** a Pure array for stateful volumes.
- **Backups:** ClickHouse and Metabase dumps go to object storage buckets; Cloud SQL runs the datalake.
