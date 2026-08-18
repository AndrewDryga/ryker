#!/bin/bash
set -euo pipefail

root=$(mktemp -d "${TMPDIR:-/tmp}/responder-findings-coverage.XXXXXX")
trap 'rm -rf "$root"' EXIT
mkdir -p "$root/internal/example" "$root/testdata/eval"

db="$root/findings.db"
/usr/bin/sqlite3 "$db" <<'SQL'
CREATE TABLE quality_findings (
  id TEXT PRIMARY KEY,
  verdict TEXT NOT NULL,
  regression_test TEXT NOT NULL
);
INSERT INTO quality_findings VALUES
  ('finding-named', 'confirmed', 'Add TestNamedRegression beside the owner.'),
  ('finding-prose', 'confirmed', 'Replay the recorded result and assert it stays silent.'),
  ('finding-eval', 'confirmed', 'Add the harvested exchange to the stateful eval corpus.');
SQL

cat > "$root/internal/example/example_test.go" <<'EOF'
package example

// Covers finding: finding-prose
func TestARealDescriptiveName() {}

// Covers: TestNamedRegression
func TestExistingBetterName() {}
EOF

cat > "$root/testdata/eval/scenarios.jsonl" <<'EOF'
{"name":"harvested exchange","tags":["finding:finding-eval"],"steps":[]}
EOF

output=$(RESPONDER_FINDINGS_ROOT="$root" \
  "$(cd "$(dirname "$0")" && pwd)/findings-coverage.sh" "$db")

if ! grep -Fq \
  'findings-coverage: 3 confirmed findings ask for a test — 3 have one, 0 do not' \
  <<<"$output"; then
  printf 'prose finding ID was not recognized as covered:\n%s\n' "$output" >&2
  exit 1
fi

echo "findings coverage tests passed"
