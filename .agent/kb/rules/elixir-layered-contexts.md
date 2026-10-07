# Ryker layered contexts

Ryker follows the layers and names of Emisar's portal
(`../emisar/portal/.agent/kb/rules/elixir-layered-contexts.md`). This note
says how each layer looks here, which Credo checks hold it, and which Emisar
rules Ryker does not follow and why. Ported 2026-10-04 to 2026-10-07.

## Layers

- **Context modules** (`Ryker.Settings`, `Ryker.Work.Custody`, ...) are the
  public functions. They call `Repo`, build transactions and decide.
- **Query modules** are `Schema.Query` in `<schema>/query.ex`. `all/0` starts
  every query with a binding named after the table
  (`from(sessions in Session, as: :episode_work_sessions)`). Every helper
  takes `queryable` first and defaults it to `all()`. A Query module never
  calls `Repo`.
- **Schema modules** hold fields, associations, `@type t` and helpers about
  one row (`Environment.writable_refs/1`). No casting or validation.
- **Changeset modules** are `Schema.Changeset` in `<schema>/changeset.ex`.
  They are pure, with one function per transition: `insert`, `update`,
  `claim`, `retire_ready`. Cast field lists live in module attributes.
- **Web modules** are any module that uses a Phoenix LiveView,
  LiveComponent, Component, Router or Endpoint. They show what a projection
  read and never call `Repo` or build changesets.
- **Page read models** are the control plane's context:
  `Ryker.ControlPlane.*Projection` loads a page, and a read model that spans
  several schemas is a concept Query module (`ControlPlane.Usage.Query`).

## Names

- Alias the schema and call its modules: `alias Ryker.Work.Session`, then
  `Session.Query.by_id/1` and `Session.Changeset.bind/2`.
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

## Enforced

`credo/checks/`, each with fixture tests in `test/ryker/credo_checks/`:

- `IL01NoInlineEctoDsl`: the Ecto DSL appears only in Query modules, and a
  read never starts at a schema (`Repo.all(Schema)`).
- `IL02NoRepoGet`: no `Repo.get`, `get!` or `get_by`.
- `IL06QueryModulePure`: Query modules never call `Repo`.
- `IL07SchemaFieldsOnly`: no changeset code in a schema module.
- `IL08ChangesetPure`: changeset modules never call `Repo`.
- `IL08ValidationInChangesets`: a module that calls `Repo` leaves `cast`,
  `validate_*`, constraint mappings and `add_error` to changeset modules.
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

## Not adopted

- **IL-3 and IL-4** (`%Auth.Subject{}` on every public context function) and
  authorizer modules: Ryker is one installation. Writes check the actor where
  they happen (`Ryker.Settings` authorizes each save); there is no subject.
- **Audit context checks**: Ryker has no audit context.
- **CrossContextDeepAlias and CrossContextDeepCall**: on 2026-10-07 Ryker had
  1,242 aliases of other contexts' modules and 1,182 calls into other
  contexts' Query and Changeset modules. Ryker's top-level directories are
  subsystems that compose each other's queries, so a context function per
  read would add hundreds of one-line wrappers.
- **WebNoNestedDomainCalls**: web modules make 93 calls into nested modules,
  almost all display helpers (`Slack.Names`, `Episodes.Words`).
- **NoIslandContainers**: the console uses its own CSS classes.
- **`use Emisar, :schema`, `:query` and `:changeset`**: Ryker uses Ecto
  directly.
- **`not_deleted/1`, `none/1`, `cursor_fields/0`, `filters/0` and
  `preloads/0`**: Ryker has no soft deletes, no authorizer and no
  `Repo.list/3`.
