#!/usr/bin/env node
process.env.FLEET_PROVIDER = 'codex';
await import('./claude-agent-acp.mjs');
