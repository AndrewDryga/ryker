<!-- Append-only working journal: what you did and WHY (decisions, dead ends,
     surprises). Add to the BOTTOM; never rewrite history. The short "where am I
     now" snapshot lives in state.md, not here. Example entry:
       ## 2026-09-04 — chose os.Rename over copy+delete
       - atomic, so a torn move can't half-create the task folder. -->

# Log — Restore Grafana and mapped JSON webhook adapters

## 2026-09-04 — restored provider transforms above generic ingress
- Added explicit universal, Grafana, and mapped-JSON route configuration with strict bounded object paths and no dynamic atom, script, module, destination, credential, or Work-authority selection from payloads.
- Derived one stable Grafana item per fingerprint/start cycle and distinct firing/resolved occurrences, with bounded normalized alert content and deterministic group correlation. Added configured mapped-JSON field selection with a host-owned actor.
- Added transactional bounded batch recording and deterministic advisory-lock ordering so a multi-alert request is all-or-nothing and concurrent reversed batches do not deadlock.
- Allowed specialized HMAC routes to derive identity from the authenticated raw body while universal routes continue to require an explicit event ID.

## 2026-09-04 — closed review findings and qualified the slice
- Added regressions proving identity-bearing fields reject overflow rather than alias after truncation, display fields stay valid UTF-8 within byte limits, and provider receipt ordering continues beyond 1,000 occurrences.
- Kept GitHub's bounded receipt-order allocator intact because its 1,000-slot ranges separate timestamp/action bands; introduced an unbounded policy only for Grafana and mapped JSON.
- Documented reverse-proxy rate limiting for the bounded 500-alert fan-out and corrected response refs and host-owned actor claims.
- Focused transform, Inbox, router, configuration, end-to-end, and capability-contract tests passed. The final isolated `make dev-check` passed with 90.01% coverage and replay 22/22. The broader `make check` remains an overall pre-shipping gate, not an intermediate iteration gate.
