package store

// schemaV52 gives a channel-setup session a pointer to its own card.
//
// The wizard posted a message per step. An operator watching
// #frontend-ops-alerts saw "1 of 4 - When should I participate?", then "2 of 4 -
// What code should I use for this channel?", then two more questions, then a
// confirmation, then a receipt: six messages in a shared alert channel to answer
// four questions, and their reaction was "can it be one message that we update?
// So that we don't spam". Editing one message needs its timestamp, and nothing
// on the session held one.
//
// thread_ts and thread_roots_json were already there and are not it. thread_ts
// is the anchor the first card established for replies, and thread_roots_json is
// the set of conversations whose replies count as setup answers — a card that
// moves into a thread adds a root and the old root keeps matching, because an
// operator who answers under the earlier question still means it. A card
// timestamp is the opposite: exactly one message, the one chat.update is allowed
// to rewrite. Overloading either would make "where may they answer" and "what do
// I edit" the same value, and they diverge the first time the setup moves.
//
// response_thread_ts becomes the card's home rather than the last reply's,
// because that is the only reading under which it can decide anything: the card
// is edited in place when it already lives where the operator is speaking, and
// reposted when it does not. Written on every reply it would report a thread the
// card is not in, and the next answer in the channel would look like a move.
//
// ADD COLUMN with a constant default, for the reason migrations 48 and 49 spell
// out: SQLite fills existing rows in place, so no table is rebuilt and no row is
// copied. Nothing here belongs in tableRebuildMigrations. Sessions that predate
// this read as empty, which is what they are — their cards were posted before
// anything recorded one — and the recovery in the service adopts the card that
// is already in the channel rather than posting a second.
const schemaV52 = `
ALTER TABLE configuration_sessions ADD COLUMN card_ts TEXT NOT NULL DEFAULT '';
`
