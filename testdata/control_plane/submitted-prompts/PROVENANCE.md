# Submitted prompts

Harvested on 2026-09-23 from the local Compose install, byte for byte, as each
model call's retained prompt text:

- `routing.json`: `admission_attempts` `d205a027-7eb3-4c4d-8792-48bbf5f4f464`,
  the routing prompt with the most candidates and conversation notes.
- `work-full.json`: `episode_work_turns` `3c45659c-2eb3-4893-8ae2-34fde021d516`,
  a full Work turn with a previous answer, related outcomes, linked history,
  records and confirmed memory.
- `work-continuation.json`: `episode_work_turns`
  `2ef22bf4-26c4-4e37-abcf-d84addf44b22`, a continuation Work turn.
- `learning.json`: `conversation_learning_runs`
  `1fd0d5f6-7f38-439c-87ed-545b025ce310`, a conversation learning pass.
- `routing-lean.json`: `admission_attempts` for input
  `2e952a97-5568-4173-bd7f-15f224a67ccd`, the first routing prompt frozen by the
  lean prompt shape (instructions first, compact messages, trimmed manifest,
  now and continuation window). The provider call failed on an expired login;
  the frozen prompt is the host's output, independent of any model answer.

The conversations are local validation chats. The prompt view left large parts
of these prompts unhighlighted (`context_manifest`, `conversation_context.current`,
`continuity`, `conversation_feedback`, `signals`) and the briefing showed the rest
only as one mixed Raw context blob.
