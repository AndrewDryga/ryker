# Emisar MCP answers

What `Ryker.TestSupport.EmisarMCP` answers, and where each answer came from.
Do not edit one to make a Ryker test pass: take it again from Emisar.

- `instructions.txt` is the `instructions` string Emisar's `initialize`
  returns, `EmisarWeb.MCP.Instructions.text/0` in the Emisar repository at
  77881b2df. It is byte for byte the text emisar.dev gave an MCP client on
  2026-09-27.
- `tools_list.json` is Emisar's `tools/list` result for four of its fourteen
  tools (find_actions, get_action, run_action, wait_for_run), compiled the way
  `EmisarWeb.MCP.SchemaRegistry` compiles them from
  `portal/apps/emisar_web/priv/mcp/api-schemas.json` (962e3b5d7, 2026-09-23):
  each descriptor without its output schema, and each input schema carrying
  only the definitions it uses.
- `find_actions.json` is the structured content of a live read-only
  `find_actions` call with the query "disk usage" and limit 2, made through an
  Emisar MCP connection on 2026-09-27. The signed cursor is replaced by
  `<opaque>`, as Emisar's own published examples do.
- `run_action_pending_approval.json` is a `run_action` answer for a run held
  for review: `EmisarWeb.MCP.ActionTools` wraps the dispatched runs as
  `ok`, `operation_id`, `action_id`, `pack_ref` and `runs`, and the run is
  Emisar's published example
  `portal/apps/emisar_web/test/fixtures/mcp/wait_for_run_review_pending_v1.json`.
  The double moves its creation time to the moment of the call and its
  approval's expiry a day later, as Emisar would answer then.
