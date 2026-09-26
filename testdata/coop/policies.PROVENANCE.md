# Coop refusing a session policy file

Each `.stderr` file is Coop's standard error, byte for byte, from
`coop sessions policies --policies <file> --json` (coop v9.0.0-485-gb6bc754a,
2026-09-26). Only the policy file's path was changed, to the path the bundled
worker loads. Coop printed nothing on standard output and exited with status 1:
it refuses the whole file over one entry.

- `policies-unsigned-account.stderr`: the `ryker-admission` policy listed
  `codex:gpt-5.6-sol/medium@emisar` and then `claude:claude-opus-4-6/high@zzqa`,
  with no Claude account `zzqa` signed in. The bundled worker (Coop
  v9.0.0-389-gcb5178eb) refuses it the same way: `LoadPolicies` checks every
  model's account.
- `policies-unsupported-effort.stderr`: the policy named
  `gemini:gemini-3-pro/medium@emisar`; Gemini takes only low and high effort.
