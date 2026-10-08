# Ryker layered contexts

Ryker follows the layers and names of Emisar's portal
(`../emisar/portal/.agent/kb/rules/elixir-layered-contexts.md`). This note
says how each layer looks here, which Credo checks hold it, and which Emisar
rules Ryker does not follow and why. Ported 2026-10-04 to 2026-10-08.

## Layers

- **Context modules** (`Ryker.Settings`, `Ryker.Work.Custody`, ...) are the
  public functions. They call `Repo`, build transactions and decide. What
  the console asks of a context is a function of its top-level module
  (`Ryker.Slack.destination_name/1`), named for what the console wants.
- **Query modules** are `Schema.Query` in `<schema>/query.ex` and start with
  `use Ryker, :query`. `all/0` starts every query with a binding named after
  the table (`from(sessions in Session, as: :episode_work_sessions)`). Every
  helper takes `queryable` first and defaults it to `all()`. A Query module
  never calls `Repo`.
- **Schema modules** start with `use Ryker, :schema`, which sets a UUIDv7
  primary key generated on insert, binary-id foreign keys and microsecond
  timestamps; a schema states only how it differs (a string `@primary_key`).
  An id a context needs before the row is written, or for `insert_all/3`,
  comes from `Repo.generate_id/0`. A schema holds fields, associations,
  `@type t` and helpers about one row (`Environment.writable_refs/1`). No
  casting or validation.
- **Changeset modules** are `Schema.Changeset` in `<schema>/changeset.ex` and
  start with `use Ryker, :changeset`. They are pure, with one function per
  transition: `insert`, `update`, `claim`, `retire_ready`. Cast field lists
  live in module attributes.
- **Web modules** are any module that uses a Phoenix LiveView,
  LiveComponent, Component, Router or Endpoint. They show what a projection
  read, never call `Repo` or build changesets, and call only a top-level
  context or the console's own `Ryker.ControlPlane.*`, never a module below
  a context (`Slack.Names`, `Settings.Environment`), in code or in a `~H`
  template.
- **Page read models** are the control plane's context:
  `Ryker.ControlPlane.*Projection` loads a page, and a read model that spans
  several schemas is a concept Query module (`ControlPlane.Usage.Query`).

## Module layout

- A module starts with `@shortdoc`, `@moduledoc` and `@behaviour`, then
  `use`, `import`, `alias` and `require`, in that order: one block with no
  blank line in it, directly under the moduledoc. Aliases in the block are
  sorted. A directive never sits inside a function or further down the
  module.
- `DateTime.utc_now/1` takes the precision it needs instead of a
  `DateTime.truncate/2` after it.

## Shared helpers

- A pure helper used in more than one module is its own small module with
  unit tests, and its callers differ only in the arguments they pass
  (Emisar's README). A boundary keeps its own error tag around the shared
  check, as `Ryker.Slack.MembershipTransition` does around
  `Slack.Timestamp.to_datetime/1`; the rule itself is written once.
- The ones there are: `Ryker.Wording` (a count and its noun, plurals,
  numbers with separators, a list in a sentence, capitals; every choice
  between one and many, "needs you" or "need you" included, goes through
  `Wording.word/3`),
  `Ryker.Text` (text in the unit its limit counts), `Ryker.ConversationRef`
  (a Slack conversation's ref, built and read one way), `Ryker.Reference`
  (reference strings, identifier tokens, UUIDs), `Ryker.Crypto.sha256_hex?/1`,
  `Ryker.UTCDateTime` (parsing, precision, UTC, ISO text, ages),
  `Ryker.Backoff` (the doubling wait and its bounds), `Ryker.Adapter` (a
  configured module that must export functions), `Ryker.Maps.put_present/3`,
  `Ryker.JSONSchema` (nonblank text, nullable), `Repo.passed?/2` (a deadline
  by the database clock), `Ryker.Lease.attempts_after_release/2`,
  `Ryker.PromptDocument` (a model prompt's text and its fitting),
  `Ryker.Coop.Documents` (a Coop session, turn, candidate answer and stop proof),
  `Ryker.Coop.RunStep` (one step of a background model run, for self-analysis
  and repository reading, each a lane with its own store),
  `Ryker.Work.ValidationContext` (what the validator is told, for the
  preflight and the executor alike), `Ryker.GitHub.repository_name?/1` and
  `id?/1`, `Ryker.GitObject.branch_ref?/1`, `Ryker.Emisar.Fields` and
  `Ryker.Slack.Client.Fields` (a boundary's field checks), `Ryker.Slack.Id`,
  `Ryker.Slack.Timestamp` and `Ryker.Slack.Permalink` (other contexts and the
  console reach them through `Ryker.Slack`), and in the console `Search`,
  `MemoryFormat`, `ChartAxis` (a chart's coordinates, for every chart),
  `ShortTime`, `Units` (`Units.compact/1` writes a count in a few
  characters, for a table and a chart's axis alike), `Kit` and
  `BackgroundCards`. A rule an offer and its action both apply lives with the
  action: `WorkControls.stoppable?/2`, `Publication.Custody.approvable?/1`.
  A standard library function beats a copy: `:inet.is_ip_address/1` checks a
  listener's address.
- A pattern a changeset checks comes from the module that owns the rule
  (`Crypto.sha256_hex_pattern/0`, `Reference.token_pattern/0`,
  `Slack.Id.pattern/0`, `GitHub.repository_name_pattern/0`).
- Not helpers: the shapes a layer requires (OTP and Plug callbacks, a page's
  `html/1`, a custody's `claim_next/2`, a Query module's own filters), a
  two-line read composed where it is used, a boundary's own error around a
  check it shares (ten modules map `Records.CardDelivery.check/3`'s two
  refusals to their own codes), and a guard-sized idiom such as
  `is_integer(value) and value > 0`, which Emisar writes inline in 27 files. `Ryker.CopiedHelpersTest` lists the copies kept on purpose,
  each with its reason.

## Names

- Alias the schema and call its modules: `alias Ryker.Work.Session`, then
  `Session.Query.by_id/1` and `Session.Changeset.bind/2`, within its own
  context. Another context's modules are named through that context's alias:
  `alias Ryker.Work`, then `Work.Session.Query.by_id/1` and `%Work.Turn{}`
  (`CrossContextDeepAlias`). A file's context is the second part of the first
  module it defines. Where a context's name is also the name of one of the
  file's own modules, the own one is named through its context
  (`EpisodeTrace.Work`, `__MODULE__.Slack` inside `Ryker.Settings`).
- `by_<field>` filters by a value. The name ends in `_id` when the argument
  is an id and has no suffix when it is a struct (`by_command(command)`).
- A filter that takes no value is named for the state it keeps: `in_force`,
  `in_use`, `delivered`, `having_result`.
- `ordered_by_*` orders. Recency uses Emisar's words (`ordered_by_recent`,
  `ordered_by_oldest`, `ordered_by_recently_updated`,
  `ordered_by_least_recently_updated`); any other order names its columns,
  with `_desc` when it runs backwards (`ordered_by_sequence_desc`).
- A helper named for a position (`latest_by_episode_id`, `oldest_due_first`)
  owns its `limit`.
- `with_joined_*` and `with_preloaded_*` are the only `with_` helpers.
  `select_*` selects and `lock_*` locks.
- Bindings are named and one letter (`[episode_work_turns: t]`), and every
  join a helper reads has an `as:`. Three helpers read the query's first
  binding instead, because they serve several schemas:
  `Learning.Visibility.Query`, `Learning.SourceDependency.Query` and
  `Memories.SearchPage.Query`.
- The transition that creates a row is `insert`. Emisar calls it `create`.
- A function that answers a boolean ends in `?`, and a `?` function answers
  nothing else: `Records.CardDelivery.check/3` answers `:ok` or why not, and
  `GitHub.Engagement.reason/3` why Ryker takes an input. A function that
  writes and answers whether it changed anything says both
  (`Slack.Names.store_changed?/4`, `AdvisoryLock.try_session?/1`). Sixteen
  were renamed and two `?` functions that answered tuples on 2026-10-08.
- A struct argument is matched by its struct in the head
  (`%Work.Session{} = session`), and a catch-all clause beside it refuses any
  other shape (32 heads on 2026-10-08). A binding names the thing, by the
  schema's name or its last word where that reads clearly
  (`%IncidentRoom{} = room`), as Emisar's 961 such bindings do.
- Variables are words: `explanation`, `{key, value}`, `conversation_ref`.
  `x` and `y` stay on a chart and `iv` in a cipher.

## Return shapes

- A public function that reads one row answers `{:ok, row}` or
  `{:error, :not_found}` (IL-5) and reads it with `Repo.fetch/2`. Custody
  locks keep their `lock_` names, and a module whose errors already name the
  missing thing keeps that reason (`{:error, :work_turn_not_found}`).
- A value a query selects (a due time, one column) stays a value or nil. Its
  pipeline names a `select_*` helper (`select_next_due_after`,
  `select_coop_session_ids`), which is how `IL05TaggedReads` tells it from a
  row.
- Lists stay plain lists: Ryker has no paginated `Repo.list/3` and no
  metadata to return beside them.
- No context function exists only for tests. A read only tests make is in
  `Ryker.Inspectors` (`test/support/inspectors.ex`); tests may read rows
  through Query modules directly.

## Writes

Emisar's write rules (`../emisar/portal/.agent/kb/rules/README.md`) that Ryker follows:

- A function that reads a row and then writes it locks it first
  (`Schema.Query.lock_for_update/1` inside the transaction), so no write
  lands between the read and the lock.
- A row whose identity is a unique key is written with one upsert
  (`on_conflict: {:replace, fields}, conflict_target: key`), and a
  fetch-or-create inserts with `on_conflict: :nothing` and reads the winner.
- Whether a row exists is never read before inserting it: the unique index
  decides in the insert itself. `insert_all` with `on_conflict: :nothing`
  answers how many rows it wrote (`Ryker.Feedback`, memory reviews); a plain
  insert that meets the index inside a transaction aborts the transaction,
  so its constraint error can never be handled there.
- A write hands back what it changed (`returning: true`, `select` on
  `update_all`) instead of reading it again; N rows go in one `insert_all`
  unless each must fail alone, which the call says.
- Each schema has its own Changeset module, and it builds changesets for that
  schema only; five Slack configuration schemas shared one until 2026-10-08.
- Fields are chosen by the changeset's `cast`, never by `Map.take/2` or
  `Map.drop/2` in a context (`ContextNoMapTakeDrop`). Crypto goes through
  `Ryker.Crypto` (`ContextCryptoBoundary`); runtime configuration a test
  changes goes through `Ryker.Config` (`NoApplicationPutEnv`).

Text and its limits (Emisar's `elixir-byte-budgets-need-byte-bounds`):

- A limit counts in the unit that enforces it. JSON Schema's `maxLength` and
  PostgreSQL's `char_length` count code points: Ryker measures with
  `Ryker.Text.char_length/1`, cuts with `Ryker.Text.characters/2`, and checks
  text a person or model wrote with `Ryker.Reference.text?/2`, never
  `String.length/1`, which counts what a reader sees as one character (a flag
  is two code points, an accent typed after its letter makes two). A byte
  limit (`octet_length`, Slack, GitHub) is measured and cut in bytes
  (`Ryker.Text.cut/2`, `Ryker.Reference.valid?/2`).
- A changeset bounds a field in its column's unit: `validate_length(field,
  max: n, count: :codepoints)` under a `char_length` check, `count: :bytes`
  under an `octet_length` one, so a long value is a field error instead of a
  constraint that raises.
- A budget made of parts is derived from their bounds
  (`Artifacts.maximum_bytes() + @maximum_lab_form_bytes`), never a second
  literal.

Functions:

- A function is public only when another module calls it, or a test of its
  module's own contract; otherwise it is `defp`, and its `@doc` becomes a
  comment.
- A private function that only hands its arguments to another call is
  inlined (Emisar's rule: a wrapper earns a name only when it adds meaning
  the call site lacks).
- A function takes only what it reads. A parameter no clause uses goes, and
  so does the chain that only passed it on (29 on 2026-10-08, among them a
  run ordinal through six trace steps). A callback keeps the shape its
  caller requires: a function plug, a `Regex.replace/3` function.
- An argument every caller must give is positional, or a field of a struct
  the head matches, never an option fetched with `Keyword.fetch!/2` (Emisar's
  always-present-arguments rule). The request page's model calls read with a
  `ModelRequests.Reading` struct; its keyword bag carried page rows, a row's
  attempt and the redactor's options together, and `disclosed` meant a set of
  opened ids to the page and a boolean to the redactor. OTP and Plug `init/1`
  options and a worker's settings from its child spec keep their keyword
  shape.
- A module attribute holds configuration: a limit, a version, a prefix, a
  pattern, a path. A message or other literal read in one place is written
  there.
- A function whose body is one `if` or `case` on its own argument, testing
  whether it or a field of it is nil, a literal or truthy, is clause heads
  instead (Emisar's `elixir-dispatch-on-pattern`): the heads show the cases
  where a reader looks first. `if` stays for a computed condition, `case` for
  anything that is not the argument (`DispatchOnPattern`, and Emisar's own
  `NoIfOnArgField` for a closure). Eighteen moved on 2026-10-08.

Docs (Emisar's `elixir-doc-contract`):

- Every public function of a top-level context has a `@doc` with its
  contract: one line on what it does, and what it returns, error reasons
  included, matching the code. A doc never narrates the body; the steps live
  in the code, and the reason for a step lives beside it as a comment.
- A function another module calls for the context's own plumbing says so:
  `@doc "Internal — ..."` and who calls it. A shared contract is said once, as
  a type every function points to (`Ryker.Settings.write_result/0`), and an
  `unsubscribe_*` twin points to the `subscribe_*` it ends.
- Query, Changeset and schema modules, and `@impl` callbacks, take their role
  from their name and need no per-function doc. Internal modules document
  what a caller needs (about half of their public functions, as in Emisar).
- Measured 2026-10-08: 448 of 448 top-level context functions documented
  (Emisar: 935 of 1,018).

Results:

- A clause never binds an `{:ok, _}` or `{:error, _}` tuple only to return
  it; it restates the tuple (`{:error, reason} -> {:halt, {:error, reason}}`)
  (`NoBoundTupleReturn`). That holds for a function clause's head too
  (`defp result({:error, reason}), do: {:error, reason}`; 37 moved on
  2026-10-08). A tuple handed on to a function keeps its name.

Stored data (Emisar's `elixir-nil-is-not-an-empty-list`):

- A list read from a map Ryker did not build in the same call (a stored
  JSON column, a decoded request, a vendor's answer) is normalized once
  where it enters, `value || []` bound to a name, before anything compares
  or walks it. The checks a write made do not hold for rows saved under an
  earlier shape.
- A map Ryker's own constructor fills needs nothing, and neither does a
  document validated where it is read: job documents (`JobSpec.digest/1`),
  worker evidence (`SessionEvidences.document/1`), record payloads
  (`RecordPayload.prepare/3`), Emisar statuses (`ApprovalStatus.prepare/1`)
  and tool arguments, which are checked against an exact schema before a
  handler runs.
- Swept 2026-10-08: of 89 places that enumerate a subscript, two read stored
  data unchecked, the improvement export's case snapshot and a webhook
  source's lifecycle scope; both normalize now. Templates walk only what
  projections built (`Ryker.ControlPlane.TemplateHygieneTest`).

Not adopted, measured 2026-10-08:

- **`Ecto.Multi` with `Repo.commit_multi`, and `Repo.fetch_and_update/3`.**
  Emisar's lib composes its transactions this way (145 `commit_multi`, 27
  `fetch_and_update`, two plain `Repo.transaction`). Ryker has 264
  `Repo.transaction` bodies in custody that nests: a context's write joins
  whatever transaction its caller opened, in a fixed lock order (a memory
  write takes the answer source, then the review lock, then the channel),
  and each refusal is a `Repo.rollback/1` reason its callers match on.
  What `commit_multi` gives Emisar beyond that, side effects after the
  outermost commit, Ryker already has (`Repo.after_commit/1`). One
  `Multi.run` around today's bodies would change only the wrapper; steps
  per custody would rewrite every caller's contract for no change in
  behaviour.
- **`Repo.transact/2` instead of `Repo.transaction/2`.** Ecto 3.14
  deprecates `transaction/2` in its documentation only, and runs it through
  `transact/2`, where Ryker's after-commit queue lives. `transact/2` commits
  on `{:ok, _}` and rolls back on `{:error, _}`, so a body moves with its
  contract.

## Migrations

- A migration is frozen once a deploy has run it; a change is a new migration.
  Ryker has no rollback command: a failed deploy restores the backup taken
  before it (`docs/operations.md`).
- A migration that rewrites rows carries frozen copies of the code it needs
  and calls no application module, which a later clean cut could rename. The
  data migrations of 2026-09-27 to 2026-09-29 call `Ryker.CanonicalJSON` and
  `KnowledgeAnchors.keys/2` once per row; every install has run them, a new
  one has no rows for them, and the next baseline removes them.
- A migration runs while Ryker is paused, so its locks are downtime. Rewrite
  a large table in batches, add a check to one `NOT VALID` and validate it
  after, and build its index `CONCURRENTLY` with `@disable_ddl_transaction`.
- Each migration has its own test (`Ryker.MigrationCase`): a scratch schema
  for one that rewrites rows, the test's transaction for one that changes a
  table's shape. Write the rows in the shape they had before the migration.
- A table or column rename (Emisar's `elixir-table-rename-sweep`) renames its
  constraints and indexes too, and updates the schema's source, every
  `name:` option and raw SQL in the same change. PostgreSQL keeps a renamed
  table's constraint names, cuts any name at 63 bytes, and Ecto infers a
  changeset's constraint names from the table, so a stale or cut name makes a
  violation raise instead of answering a changeset error. A constraint on
  more than one column, or with a cut name, is declared with its real
  `name:`. `Ryker.ConstraintNamesTest` checks that every constraint a
  changeset declares exists.

## Tests

Emisar's test rules Ryker follows (`elixir-layered-contexts.md` §7 there):

- A fully known result is asserted with `==` (`assert Settings.fetch() ==
  {:error, :not_found}`); `=` binds or matches part of a value, and a map
  pattern or a float stays a match (`TestAssertKnownResult`).
- The context of a test is an explicit `%{...}` pattern (`TestContextPattern`),
  no `Process.sleep` synchronizes (`TestNoProcessSleep`), fixtures are named
  per domain and never imported, and a read only tests make lives in
  `Ryker.Inspectors`.
- Logs are captured at the ExUnit boundary (`capture_log: true`), and the
  code under test prints nothing else: git runs keep their errors and log one
  line on failure, and a test remote serves partial clones as GitHub does.

Not adopted, because Ryker's own test rules (CLAUDE.md) differ:

- **A `describe "fun/arity"` per public function, in module order, with a
  coverage test.** Ryker names each test after the invariant it holds and
  groups tests by behaviour, which usually crosses several functions.
- **No narrative comments in a test body.** Ryker asks every regression test
  to record what it is holding shut and what the defect cost, so a reader
  does not delete it as redundant.

## Phoenix safety

- IL-14: no `String.to_atom/1` on outside input (none in `lib`).
- IL-15: the console's trust is reach plus the identity Tailscale Serve or
  Cloudflare Access names (`Ryker.ControlPlane.Viewer`). There are no roles to
  check per event. An Access sign-in has an end: the socket checks it when
  it connects, and an open page reloads the moment it ends, so no event runs
  past it (`WorkbenchLive`, `:sign_in_ended`).
- IL-16: `raw/1` only on HTML Ryker's own builders produced with every value
  escaped, and each builder has a test that feeds it markup.
- IL-17: every long-lived process is under a supervisor.
- IL-18: `mount` reads nothing (one `connected?`-guarded write names the
  viewer), subscriptions wait for `connected?` (`SubscribeNeedsConnected`),
  Activity and Chat stream their rows, and no per-mount value uses
  `assign_new`. A page is read for its first render and again when its
  socket connects; the first paint shows the page instead of a blank one
  (decided 2026-10-04).
- IL-19: vendor APIs go through Ryker's own modules (`VendorViaWrapper`).
- A form's refusal stays with the form (Emisar's `elixir-inline-form-errors`):
  what the person chose or typed is kept, and why it was refused shows
  beside it. The relearning panel submits through the LiveView; the fact
  correction form is drawn again with its words. A confirmation with nothing
  typed answers its refusal on the page that says why, with the way back,
  never a line of plain text.

Model-facing tools (Emisar's `elixir-model-authoring-validation-is-actionable`):

- A state-tool call that breaks its schema answers each field it breaks, by
  JSON Pointer, with a stable code and the rule in words, never the value
  sent: the first eight and how many there were
  (`StateTools.SchemaCheck`, `StateTools.ErrorCode`). A domain refusal names
  its field (`{:invalid_state_record, field}`, `{:invalid_schedule, field}`).
- Authorization runs before validation, and validation before anything is
  written.

## Enforced

`credo/checks/`, each with fixture tests in `test/ryker/credo_checks/`:

- `IL01NoInlineEctoDsl`: the Ecto DSL appears only in Query modules, and a
  read never starts at a schema (`Repo.all(Schema)`).
- `IL02NoRepoGet`: no `Repo.get`, `get!` or `get_by`.
- `IL05TaggedReads`: a public function's result is never a bare `Repo.one`
  of whole rows.
- `IL06QueryModulePure`: Query modules never call `Repo`.
- `IL07SchemaFieldsOnly`: no changeset code in a schema module.
- `IL08ChangesetPure`: changeset modules never call `Repo`.
- `IL08ValidationInChangesets`: a module that calls `Repo` leaves `cast`,
  `validate_*`, constraint mappings and `add_error` to changeset modules.
- `CrossContextDeepAlias`: no alias reaches into another context's modules.
  Credo's own `AliasUsage` is off, as in Emisar: it asks for those aliases.
- `UseRykerRole`: schema, Query and Changeset modules take their role from
  `use Ryker`, and no other module does.
- `WebNoNestedDomainCalls`: a web module calls a top-level context, never a
  module below one, in code or in a `~H` template.
- `NoBoundTupleReturn`: no tuple bound only to be returned.
- `DispatchOnPattern` and `NoIfOnArgField`: a body that only dispatches on
  its argument is clause heads.
- `TestAssertKnownResult`: a fully known result is asserted with `==`.
- `NoBlankBetweenDirectives` with Credo's `StrictModuleLayout`: the module
  header's order and one block; `UtcNowTruncate` and
  `WrongTestFileExtension`, which Emisar enables too.
- `IL12NoFloatMoney`, `WebNoRepoCalls`, `WebNoChangesetConstruction`, and the
  house style checks listed in `.credo.exs`.

Tests hold the rest: `Ryker.TypespecsTest` resolves every remote type a spec
names, `Ryker.ConstraintNamesTest` finds every constraint a changeset
declares, `Ryker.CopiedHelpersTest` finds a function copied between modules,
`Ryker.ControlPlane.TemplateHygieneTest` keeps templates off raw
subscripts, and `Ryker.DataCase` fails an async test that saves settings.

## Ryker conventions Emisar does not have

- Advisory locks go through `Ryker.AdvisoryLock`.
- A transaction's timeouts are `Repo.statement_timeout!/1` and
  `Repo.lock_timeout!/1`. The database clock is `Repo.now!/0`.
- Rows with a lease share their transitions through `Ryker.Lease.Changeset`,
  beside `Ryker.Lease`.
- Whether a worker still holds a row's lease is `Ryker.Lease.held?/3`, and a
  renewal's expiry is `Ryker.Lease.renewed/3`; no custody keeps its own copy.
- A reference string is checked by `Ryker.Reference`: a boundary keeps its
  own error tag (`Reference.check(value, field, boundary, maximum)`), never
  its own copy of the rule.

## Not adopted

- **IL-3 and IL-4** (`%Auth.Subject{}` on every public context function) and
  authorizer modules: Ryker is one installation. Writes check the actor where
  they happen (`Ryker.Settings` authorizes each save); there is no subject.
- **Audit context checks**: Ryker has no audit context.
- **NoIslandContainers** (a page template paints no box of its own): Ryker's
  console draws with the Kit's classes and no utility classes, so the check
  has nothing to read. The rule holds by construction: every box is a Kit
  part.
- **CrossContextDeepCall** (another context's Query and Changeset modules
  called only by that context). Measured 2026-10-08: 869 calls in 123 files
  outside the Query modules and the read-model layers (the console's
  projections and Observability, the role Emisar's Audit resolvers play),
  647 targets. Emisar's reason is its authorization boundary: a
  `%Subject{}` gate and `for_subject/2` row scoping run only inside a
  context, so a nested call runs outside them. Ryker has neither (IL-3 and
  IL-4 above), and its directories share tables: `episode_work_sessions`
  holds Work, Admission, Learning, Improvement and Knowledge sessions, and
  custody locks episodes, turns and sessions of several directories in one
  transaction, in a fixed order. Moving each read and write behind the
  owning directory would add about 500 single-use functions without
  changing what any of them reads, writes or locks. What holds instead:
  queries are built only in Query modules (IL-1), another context's modules
  are named through it (`CrossContextDeepAlias`), and transitions every
  custody shares live at the top (`Ryker.Lease.Changeset`).
- **NoIslandContainers**: the console uses its own CSS classes, not
  Tailwind's, so the class pattern it looks for never appears.
- **No client-side draft store for an ordinary form**
  (`elixir-preserve-operator-form-input`). Ryker keeps typed text in the
  tab: the Chat composer per conversation since 2026-09-05, instruction
  drafts since 09-10, settings and environment forms since 09-11 ("ask
  before navigating away from an unsaved section"). They are features
  Andrew asked for, so they stay; Emisar's reasons are met instead: the
  store is one module (`priv/static/draft-store.mjs`) with JavaScript tests,
  drafts are pruned after a day or past the newest fifty, and a draft is
  taken back only against the revision it began from. Fields are also
  server-tracked, so a re-render or a reconnect keeps what was typed.
- **One embedded `settings` value per schema** (`elixir-embedded-settings`).
  Ryker's settings are their own context: one table per section, each
  column with its own database check, every save revisioned and recorded,
  and one read (`Settings.fetch/0`) for all of them. The rule's reason, a
  domain table gathering one column and one accessor per toggle, does not
  arise.
- **Owner access** and **runbook draft edits**: Emisar's roles and runbooks.
  Ryker has neither; its nearest case, a corrected candidate, already
  updates the task's existing pull request instead of opening another.
- **`not_deleted/1`, `none/1`, `cursor_fields/0`, `filters/0` and
  `preloads/0`**: Ryker has no soft deletes, no authorizer and no
  `Repo.list/3`.
