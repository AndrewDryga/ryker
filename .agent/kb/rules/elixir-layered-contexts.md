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
- A write hands back what it changed (`returning: true`, `select` on
  `update_all`) instead of reading it again; N rows go in one `insert_all`
  unless each must fail alone, which the call says.
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
- A module attribute holds configuration: a limit, a version, a prefix, a
  pattern, a path. A message or other literal read in one place is written
  there.

Results:

- A clause never binds an `{:ok, _}` or `{:error, _}` tuple only to return
  it; it restates the tuple (`{:error, reason} -> {:halt, {:error, reason}}`)
  (`NoBoundTupleReturn`). A tuple handed on to a function keeps its name.

Not adopted yet (2026-10-08):

- **`Ecto.Multi` with `Repo.commit_multi`, and `Repo.fetch_and_update/3`.**
  Emisar's lib composes its transactions this way (145 `commit_multi` and 27
  `fetch_and_update` calls, two plain `Repo.transaction`). Ryker has 264
  `Repo.transaction` bodies in deep custody that call each other in fixed
  lock orders (a memory write takes the answer source, then the review lock,
  then the channel), and each refusal is a `Repo.rollback/1` reason its
  callers match on, so each moves together with its callers.
- **`Repo.transact/2` instead of `Repo.transaction/2`.** Ecto 3.14
  deprecates `transaction/2` in its documentation only. `transact/2` commits
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
- `NoBlankBetweenDirectives` with Credo's `StrictModuleLayout`: the module
  header's order and one block; `UtcNowTruncate` and
  `WrongTestFileExtension`, which Emisar enables too.
- `IL12NoFloatMoney`, `WebNoRepoCalls`, `WebNoChangesetConstruction`, and the
  house style checks listed in `.credo.exs`.

Tests hold the rest: `Ryker.TypespecsTest` resolves every remote type a spec
names, and `Ryker.DataCase` fails an async test that saves settings.

## Ryker conventions Emisar does not have

- Advisory locks go through `Ryker.AdvisoryLock`.
- A transaction's timeouts are `Repo.statement_timeout!/1` and
  `Repo.lock_timeout!/1`. The database clock is `Repo.now!/0`.
- Delivery rows with a lease share their transitions through
  `Ryker.Delivery.Lease.Changeset`.
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
- **CrossContextDeepCall**, not yet (2026-10-08): 1,227 calls into other
  contexts' Query and Changeset modules in 167 files (647 targets).
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
- **`not_deleted/1`, `none/1`, `cursor_fields/0`, `filters/0` and
  `preloads/0`**: Ryker has no soft deletes, no authorizer and no
  `Repo.list/3`.
