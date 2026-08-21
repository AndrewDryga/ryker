package migrationddl

// V90 keeps the authoritative destination for a GitHub check summary. Existing
// follow-ups fall back to their PR until the next ordinary poll records a run.
const V90 = `
ALTER TABLE publication_followups ADD COLUMN checks_url TEXT NOT NULL DEFAULT '';
`
