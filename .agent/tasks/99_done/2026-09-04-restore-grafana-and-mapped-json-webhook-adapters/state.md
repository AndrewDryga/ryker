<!-- Resume snapshot — OVERWRITE this whole file at each checkpoint (before a
     commit or pause) so a fresh agent can resume cold. Keep it short; this is NOT
     a journal (that's log.md). -->

# State — Restore Grafana and mapped JSON webhook adapters

**Status:** complete
**Done so far:** Added strict tagged universal, Grafana, and mapped-JSON routes; atomic multi-input custody; stable Grafana cycle and occurrence identity; durable unbounded provider receipt-order revisions; bounded mapping paths and content; exact-body bearer/HMAC admission; documentation and capability-contract updates. Review findings for identity truncation, UTF-8 byte bounds, actor authority, batch fan-out, and revision exhaustion are resolved or documented.
**Next action:** none
**Traps:** Keep GitHub and Conversation Lab on the existing 1,000-slot receipt-order policy because GitHub uses semantic timestamp/action bands. Grafana and mapped JSON intentionally use receipt_order_unbounded. Public deployments must rate-limit authenticated webhook senders at the reverse proxy because one Grafana request may contain up to 500 alerts.
