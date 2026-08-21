package migrationddl

// V89 keeps the check summary as data instead of forcing every card to parse a
// sentence written for Slack. Existing follow-ups start unknown; the next
// ordinary GitHub poll fills the counts from the checks API.
const V89 = `
ALTER TABLE publication_followups ADD COLUMN checks_total INTEGER NOT NULL DEFAULT 0;
ALTER TABLE publication_followups ADD COLUMN checks_passed INTEGER NOT NULL DEFAULT 0;
ALTER TABLE publication_followups ADD COLUMN checks_failed INTEGER NOT NULL DEFAULT 0;
`
