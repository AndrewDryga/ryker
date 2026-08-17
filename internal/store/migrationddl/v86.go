package migrationddl

// V86 keeps the observable success condition beside a scheduled wakeup.
//
// A timer that remembers only when to wake and which provider object to read
// cannot remember what the operator was promised it would prove. The 0754fcb5
// Terraform follow-up intended to verify eight routed services and resumed
// with only the run id, so the result and its Slack label both collapsed to a
// generic "scheduled follow-up".
const V86 = `
ALTER TABLE episode_wakeups ADD COLUMN verification TEXT NOT NULL DEFAULT '';
`
