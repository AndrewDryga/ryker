defmodule Ryker.Settings do
  @moduledoc """
  Typed durable product settings behind one installation identity.

  Every domain row is edited through the same write path: the caller is the
  authenticated local settings boundary, the expected global revision must
  match under a transaction lock, the typed changeset must validate as a whole,
  a normalized no-op costs nothing, and every real change records an edit
  receipt with a content fingerprint. A failed database read is never an
  absent setting: only a missing installation row means "not initialized".
  """
  alias Ryker.Accounting
  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.Crypto
  alias Ryker.Emisar
  alias Ryker.Repo
  alias Ryker.Settings.{Edit, EmisarConnection}
  alias Ryker.Settings.Environment
  alias Ryker.Settings.{EnvironmentRepository, GitHub, GitHubBinding}
  alias Ryker.Settings.{Installation, Learning}
  alias Ryker.Settings.PricingRate
  alias Ryker.Settings.{Publication, Report}
  alias Ryker.Settings.Repository
  alias Ryker.Settings.{Retention, RetentionImpact}
  alias Ryker.Settings.{Validation, WebhookSource}
  alias Ryker.Slack
  alias Ryker.Work

  @actor "control-plane:local"
  @tailnet_actor "control-plane:tailscale:"
  @cloudflare_actor "control-plane:cloudflare:"
  @lock_tag "ryker-settings"
  @day 86_400
  # Keeping routing or work examples for training is off until a person turns it on.
  @retention_defaults %{
    operational_data_seconds: 30 * @day,
    conversation_memory_seconds: 90 * @day,
    closed_work_seconds: 30 * @day,
    episode_history_seconds: 30 * @day,
    audit_data_seconds: 30 * @day,
    routing_examples_enabled: false,
    routing_examples_seconds: 365 * @day,
    work_examples_enabled: false,
    work_examples_seconds: 365 * @day
  }
  @retention_fields Map.keys(@retention_defaults)
  @application_failures [:assembly_failed, :runtime_start_failed]
  # Each kind of item a list of settings holds: the snapshot list it is in,
  # the field that names it, and the changeset module that writes it.
  @items %{
    EmisarConnection => {:emisar_connections, :ref, EmisarConnection.Changeset},
    Environment => {:environments, :ref, Environment.Changeset},
    GitHubBinding => {:github_bindings, :name, GitHubBinding.Changeset},
    PricingRate => {:pricing_rates, :id, PricingRate.Changeset},
    Repository => {:repositories, :ref, Repository.Changeset},
    WebhookSource => {:webhook_sources, :name, WebhookSource.Changeset}
  }
  @type snapshot :: %{
          installation: Installation.t(),
          retention: Retention.t(),
          slack: __MODULE__.Slack.t(),
          work: __MODULE__.Work.t(),
          github: GitHub.t(),
          publication: Publication.t(),
          emisar_connections: [EmisarConnection.t()],
          report: Report.t(),
          learning: Learning.t(),
          repositories: [Repository.t()],
          environments: [Environment.t()],
          github_bindings: [GitHubBinding.t()],
          webhook_sources: [WebhookSource.t()],
          pricing_rates: [PricingRate.t()]
        }

  def retention_defaults, do: @retention_defaults

  @doc """
  Runs several settings writes as one change.

  The writes `operation` makes commit together or not at all, and the runtime
  hears the saved revision once, after the commit (`subscribe/0`).
  `operation` returns `{:ok, value}` or `{:error, reason}`; an error rolls
  every write back.
  """
  @spec atomically((-> {:ok, term()} | {:error, term()})) :: {:ok, term()} | {:error, term()}
  def atomically(operation) when is_function(operation, 0) do
    Repo.transaction(fn ->
      case operation.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  The current consistent snapshot, or an explicit not-initialized error.

  The snapshot is fourteen reads, each seeing whatever had committed before
  it: a fetch during an import could return the binding without its
  repository, and the runtime built from it ran without GitHub (2026-10-04
  review). Every write moves the revision, so a read that finds it unchanged
  at the end saw no write land in between. One that finds it moved reads again
  under the settings lock, shared, which waits for a write in flight and lets
  none start until it is done.
  """
  @spec fetch() :: {:ok, snapshot()} | {:error, :settings_not_initialized}
  def fetch do
    case read() do
      {:ok, snapshot} ->
        if moved?(snapshot.installation), do: read_locked(), else: {:ok, snapshot}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read do
    case Repo.one(Installation.Query.all()) do
      nil -> {:error, :settings_not_initialized}
      %Installation{} = installation -> {:ok, load(installation)}
    end
  end

  defp moved?(%Installation{revision: revision}),
    do: Repo.one(Installation.Query.select_revision()) != revision

  defp read_locked do
    {:ok, fetched} =
      Repo.transaction(fn ->
        AdvisoryLock.hold!(@lock_tag, :shared)
        read()
      end)

    fetched
  end

  def fetch! do
    case fetch() do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> raise ArgumentError, "settings unavailable: #{inspect(reason)}"
    end
  end

  @doc """
  The recorded Slack workspace origin, or nil when none has been saved.

  Card projections ask this per card they build, so it reads the one column it
  needs rather than the whole settings snapshot.
  """
  @spec slack_workspace_url() :: String.t() | nil
  def slack_workspace_url, do: Repo.one(__MODULE__.Slack.Query.select_workspace_url())

  @doc """
  The enrolled worker workspace Work runs in, or nil when none is selected.

  The recovery surfaces ask this once per blocked row; loading the whole
  settings snapshot for one string would make a failures page pay fourteen
  queries a row for it.
  """
  @spec worker_workspace_ref() :: String.t() | nil
  def worker_workspace_ref, do: Repo.one(__MODULE__.Work.Query.select_workspace_ref())

  @doc """
  The GitHub API the installation's App talks to.

  Every repository file Ryker reads asks this; it read the whole settings
  snapshot for this one string on each file (2026-10-04 review).
  """
  @spec github_api_url() :: String.t()
  def github_api_url, do: Repo.one(GitHub.Query.select_api_url()) || %GitHub{}.api_url

  @doc "The default environment of a settings snapshot, or nil when none is chosen."
  @spec default_environment(snapshot()) :: Environment.t() | nil
  def default_environment(snapshot), do: Enum.find(snapshot.environments, & &1.is_default)

  @doc "The environment `ref` names in a settings snapshot, or nil."
  @spec environment(snapshot(), String.t() | nil) :: Environment.t() | nil
  def environment(snapshot, ref), do: find_item(snapshot, Environment, ref)

  @doc """
  The repositories work pinned to `repository_ref` in the environment `ref`
  may change: its own, and any other its environment lets it write.
  """
  @spec writable_repositories(snapshot(), String.t() | nil, String.t() | nil) :: [String.t()]
  def writable_repositories(snapshot, ref, repository_ref) do
    writable =
      case is_binary(ref) && environment(snapshot, ref) do
        %Environment{} = environment -> Environment.writable_refs(environment)
        _none -> []
      end

    [repository_ref | writable] |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  @doc """
  The environment GitHub events for a repository run in.

  The first environment (by ref) whose default repository it is, else the
  first that may change it, else the first that holds it, else nil: the
  repository then runs on its own.
  """
  @spec environment_for_repository([Environment.t()], String.t()) :: Environment.t() | nil
  def environment_for_repository(environments, repository_ref) do
    ordered = Enum.sort_by(environments, & &1.ref)

    Enum.find(ordered, &(List.first(Environment.repository_refs(&1)) == repository_ref)) ||
      Enum.find(ordered, &(repository_ref in Environment.writable_refs(&1))) ||
      Enum.find(ordered, &(repository_ref in Environment.repository_refs(&1)))
  end

  @doc "Creates the single installation identity and typed defaults exactly once."
  def initialize(actor_ref) do
    with :ok <- authorize(actor_ref) do
      transaction(fn -> initialize_locked(actor_ref) end)
    end
  end

  defp initialize_locked(actor_ref) do
    # The lock fences simultaneous first saves so they agree on one identity.
    lock!()

    case Repo.one(Installation.Query.all()) do
      %Installation{} = installation -> load(installation)
      nil -> insert_installation!(generate_host_ref(), actor_ref)
    end
  end

  @doc """
  Whether the newest revision is a person's save, from the control plane or
  from Slack, rather than GitHub's webhook or repository setup recording its
  progress. Only a person's save is announced as being applied: setup writes a
  revision per step, and announcing each one blinked a notice on every
  settings page for as long as setup ran.
  """
  @spec saved_by_person?(snapshot()) :: boolean()
  def saved_by_person?(%{installation: %{saved_by: saved_by}}), do: person?(saved_by)

  defp person?(@actor), do: true
  defp person?(@tailnet_actor <> _login), do: true
  defp person?(@cloudflare_actor <> _login), do: true
  defp person?("slack:user:" <> _user_ref), do: true
  defp person?(_system), do: false

  @spec application_status(snapshot()) :: :pending | :applied | {:failed, atom()}
  def application_status(%{installation: installation}) do
    cond do
      is_binary(installation.failure_code) ->
        {:failed, String.to_existing_atom(installation.failure_code)}

      installation.applied_revision == installation.revision ->
        :applied

      true ->
        :pending
    end
  end

  @doc "Records the outcome of applying exactly the current revision to the runtime."
  def record_application(revision, result) when is_integer(revision) and revision > 0 do
    with {:ok, failure_code} <- application_result(result),
         {:ok, :ok} <- transaction(fn -> record_application_locked(revision, failure_code) end) do
      broadcast_settings_applied(revision)
    end
  end

  def record_application(_revision, _result), do: {:error, :invalid_settings_application_result}

  defp record_application_locked(revision, failure_code) do
    lock!()

    case Repo.one(Installation.Query.all()) do
      nil ->
        Repo.rollback(:settings_not_initialized)

      %Installation{revision: ^revision} = installation ->
        changes =
          if failure_code,
            do: %{failure_code: Atom.to_string(failure_code)},
            else: %{applied_revision: revision, failure_code: nil}

        installation |> Ecto.Changeset.change(changes) |> Repo.update!()
        :ok

      %Installation{} ->
        Repo.rollback(:settings_revision_changed)
    end
  end

  defp application_result(:ok), do: {:ok, nil}

  defp application_result({:error, code}) when code in @application_failures,
    do: {:ok, code}

  defp application_result(_result), do: {:error, :invalid_settings_application_result}

  # Retention -----------------------------------------------------------------

  def preview_retention(attributes, expected_revision) do
    with {:ok, attributes} <- Validation.attributes(attributes, @retention_fields) do
      transaction(fn -> retention_preview(current!(expected_revision), attributes) end)
    end
  end

  defp retention_preview(snapshot, attributes) do
    proposed = retention_target!(snapshot.retention, attributes)

    %{
      confirmation: retention_confirmation(proposed, snapshot.installation.revision),
      current_revision: snapshot.installation.revision,
      impact: RetentionImpact.estimate(snapshot.retention, proposed),
      proposed: proposed,
      shortened_fields: shortened_fields(snapshot.retention, proposed)
    }
  end

  def save_retention(attributes, expected_revision, actor_ref, confirmation \\ nil) do
    with :ok <- authorize(actor_ref),
         {:ok, attributes} <- Validation.attributes(attributes, @retention_fields) do
      save(:retention, expected_revision, actor_ref, fn snapshot ->
        retention_change(
          snapshot,
          retention_target!(snapshot.retention, attributes),
          confirmation
        )
      end)
    end
  end

  defp retention_change(snapshot, proposed, confirmation) do
    shortened = shortened_fields(snapshot.retention, proposed)

    cond do
      proposed == Map.take(snapshot.retention, @retention_fields) ->
        :unchanged

      shortened != [] and
          confirmation != retention_confirmation(proposed, snapshot.installation.revision) ->
        Repo.rollback(:retention_impact_confirmation_required)

      true ->
        snapshot.retention |> Ecto.Changeset.change(proposed) |> Repo.update!()
        {:changed, proposed}
    end
  end

  defp retention_target!(current, attributes) do
    proposed = current |> Map.take(@retention_fields) |> Map.merge(attributes)

    case Validation.retention(proposed) do
      {:ok, values} -> values
      {:error, reason} -> Repo.rollback({:invalid_settings, reason})
    end
  end

  defp shortened_fields(current, proposed) do
    @retention_fields
    |> Enum.filter(&shortened?(&1, current, proposed))
    |> Enum.sort()
  end

  # Turning off keeping routing or work examples deletes the ones kept, so it
  # asks first, like a shorter limit. While none are kept, a shorter limit for
  # them deletes nothing and asks nothing.
  defp shortened?(:routing_examples_enabled, current, proposed),
    do: current.routing_examples_enabled and not proposed.routing_examples_enabled

  defp shortened?(:routing_examples_seconds, current, proposed) do
    current.routing_examples_enabled and
      proposed.routing_examples_seconds < current.routing_examples_seconds
  end

  defp shortened?(:work_examples_enabled, current, proposed),
    do: current.work_examples_enabled and not proposed.work_examples_enabled

  defp shortened?(:work_examples_seconds, current, proposed) do
    current.work_examples_enabled and
      proposed.work_examples_seconds < current.work_examples_seconds
  end

  defp shortened?(field, current, proposed),
    do: Map.fetch!(proposed, field) < Map.fetch!(current, field)

  defp retention_confirmation(proposed, revision) do
    CanonicalJSON.digest(%{"revision" => revision, "retention" => stringify(proposed)})
  end

  # Singleton domains ---------------------------------------------------------

  def save_slack(attributes, expected_revision, actor_ref) do
    save_singleton(:slack, __MODULE__.Slack.Changeset, attributes, expected_revision, actor_ref)
  end

  def save_github(attributes, expected_revision, actor_ref),
    do: save_singleton(:github, GitHub.Changeset, attributes, expected_revision, actor_ref)

  def save_publication(attributes, expected_revision, actor_ref) do
    save_singleton(:publication, Publication.Changeset, attributes, expected_revision, actor_ref)
  end

  def save_report(attributes, expected_revision, actor_ref),
    do: save_singleton(:report, Report.Changeset, attributes, expected_revision, actor_ref)

  def save_learning(attributes, expected_revision, actor_ref),
    do: save_singleton(:learning, Learning.Changeset, attributes, expected_revision, actor_ref)

  def save_work(attributes, expected_revision, actor_ref),
    do: save_singleton(:work, __MODULE__.Work.Changeset, attributes, expected_revision, actor_ref)

  @doc """
  Sets the installation-wide participation default from a Slack operator command.

  The Slack surface has no editor draft to protect, so it writes against the
  revision it reads under the same lock; the authorization check is the operator
  membership saved in these settings, never the Slack payload's own claim.
  """
  def save_default_participation(value, actor_ref)
      when value in [:mentions, :proactive, :shadow] do
    with :ok <- authorize(actor_ref) do
      save(:slack, :current, actor_ref, fn snapshot ->
        write_changeset(
          snapshot.slack,
          __MODULE__.Slack.Changeset.update(
            snapshot.slack,
            %{default_participation: value},
            snapshot
          )
        )
      end)
    end
  end

  def save_default_participation(_value, _actor_ref),
    do: {:error, {:invalid_settings, [{:default_participation, :inclusion}]}}

  defp save_singleton(domain, section, attributes, expected_revision, actor_ref) do
    with :ok <- authorize(actor_ref),
         {:ok, attributes} <- Validation.attributes(attributes, section.fields()) do
      save(domain, expected_revision, actor_ref, fn snapshot ->
        current = Map.fetch!(snapshot, domain)
        write_changeset(current, section.update(current, attributes, snapshot))
      end)
    end
  end

  defp write_changeset(current, changeset) do
    cond do
      not changeset.valid? ->
        Repo.rollback({:invalid_settings, Validation.errors(changeset)})

      current && changeset.changes == %{} ->
        :unchanged

      current ->
        {:changed, changeset |> Repo.update!() |> stringify()}

      true ->
        {:changed, changeset |> Repo.insert!() |> stringify()}
    end
  end

  # Collections ---------------------------------------------------------------

  def put_repository(attributes, expected_revision, actor_ref),
    do: put_item(:repositories, Repository, attributes, expected_revision, actor_ref)

  @doc """
  Saves a change to a repository that is still added, at whatever revision
  the settings are at: a step of Ryker's own, such as setup, never conflicts
  with a person's save. A removed repository stays removed
  (`{:error, :repository_removed}`).
  """
  def update_repository(ref, attributes, actor_ref) when is_binary(ref) do
    with :ok <- authorize(actor_ref),
         {:ok, attributes} <-
           Validation.attributes(Map.put(attributes, :ref, ref), Repository.Changeset.fields()) do
      save(:repositories, :current, actor_ref, &update_found_repository(&1, ref, attributes))
    end
  end

  defp update_found_repository(snapshot, ref, attributes) do
    case find_item(snapshot, Repository, ref) do
      nil ->
        Repo.rollback(:repository_removed)

      current ->
        write_changeset(current, Repository.Changeset.update(current, attributes, snapshot))
    end
  end

  @doc """
  Removes a repository. Its requests, usage and learned topics keep its ref,
  so the name it was known by is kept (`removed_repository_names`) and they
  still read owner/repo.
  """
  def delete_repository(ref, expected_revision, actor_ref) do
    with :ok <- authorize(actor_ref) do
      save(:repositories, expected_revision, actor_ref, fn snapshot ->
        repository = find_item(snapshot, Repository, ref)
        deleted = delete_found(Repository, repository, snapshot)
        keep_removed_name!(repository)
        deleted
      end)
    end
  end

  defp keep_removed_name!(%Repository{ref: ref} = repository) do
    case Enum.find(
           [repository.github_repository, repository.display_name],
           &(&1 not in [nil, ""])
         ) do
      nil ->
        :ok

      name ->
        Repo.insert_all(
          "removed_repository_names",
          [%{ref: ref, name: name, inserted_at: DateTime.utc_now()}],
          on_conflict: {:replace, [:name, :inserted_at]},
          conflict_target: :ref
        )

        :ok
    end
  end

  @doc """
  Creates or edits one environment.

  `repositories` lists its repository refs, the default first, and `access`
  maps a repository ref to `:read_write`, which a task may change, or
  `:read_only`, which work only reads; see `Ryker.Settings.Environment`.
  Making an environment the default takes the default from whichever
  environment had it, in the same revision.
  """
  def put_environment(attributes, expected_revision, actor_ref),
    do: put_item(:environments, Environment, attributes, expected_revision, actor_ref)

  def delete_environment(ref, expected_revision, actor_ref),
    do: delete_item(:environments, Environment, ref, expected_revision, actor_ref)

  def put_emisar_connection(attributes, expected_revision, actor_ref),
    do: put_item(:emisar, EmisarConnection, attributes, expected_revision, actor_ref)

  def delete_emisar_connection(ref, expected_revision, actor_ref) do
    atomically(fn ->
      with {:ok, snapshot} <-
             delete_item(:emisar, EmisarConnection, ref, expected_revision, actor_ref),
           :ok <- Ryker.Credentials.delete(:emisar, ref, actor_ref),
           do: {:ok, snapshot}
    end)
  end

  def put_github_binding(attributes, expected_revision, actor_ref),
    do: put_item(:github, GitHubBinding, attributes, expected_revision, actor_ref)

  def delete_github_binding(name, expected_revision, actor_ref),
    do: delete_item(:github, GitHubBinding, name, expected_revision, actor_ref)

  def put_webhook_source(attributes, expected_revision, actor_ref),
    do: put_item(:webhooks, WebhookSource, attributes, expected_revision, actor_ref)

  def delete_webhook_source(name, expected_revision, actor_ref),
    do: delete_item(:webhooks, WebhookSource, name, expected_revision, actor_ref)

  def put_pricing_rate(attributes, expected_revision, actor_ref),
    do: put_item(:pricing, PricingRate, attributes, expected_revision, actor_ref)

  def delete_pricing_rate(id, expected_revision, actor_ref),
    do: delete_item(:pricing, PricingRate, id, expected_revision, actor_ref)

  defp put_item(domain, schema, attributes, expected_revision, actor_ref) do
    {_collection, key, section} = Map.fetch!(@items, schema)

    with :ok <- authorize(actor_ref),
         {:ok, attributes} <- Validation.attributes(attributes, section.fields()) do
      save(domain, expected_revision, actor_ref, fn snapshot ->
        current = find_item(snapshot, schema, Map.get(attributes, key))
        write_item(current, item_changeset(section, current, attributes, snapshot))
      end)
    end
  end

  defp item_changeset(section, nil, attributes, snapshot),
    do: section.insert(attributes, snapshot)

  defp item_changeset(section, current, attributes, snapshot),
    do: section.update(current, attributes, snapshot)

  defp find_item(snapshot, schema, value) do
    {collection, key, _section} = Map.fetch!(@items, schema)
    Enum.find(Map.fetch!(snapshot, collection), &(Map.fetch!(&1, key) == value))
  end

  defp item_key(schema), do: @items |> Map.fetch!(schema) |> elem(1)

  # An environment's repositories are rows of their own, written beside it.
  defp write_item(current, %Ecto.Changeset{data: %Environment{}} = changeset),
    do: write_environment(current, changeset)

  defp write_item(current, changeset), do: write_changeset(current, changeset)

  defp write_environment(current, changeset) do
    cond do
      not changeset.valid? ->
        Repo.rollback({:invalid_settings, Validation.errors(changeset)})

      current && changeset.changes == %{} ->
        :unchanged

      true ->
        now = DateTime.utc_now()
        ref = Ecto.Changeset.get_field(changeset, :ref)

        # The partial unique index allows one default, so the previous one
        # yields before this row claims it.
        if Ecto.Changeset.get_change(changeset, :is_default) == true do
          Repo.update_all(Environment.Query.other_defaults(ref),
            set: [is_default: false, updated_at: now]
          )
        end

        changeset = Ecto.Changeset.force_change(changeset, :updated_at, now)

        environment =
          if current,
            do: Repo.update!(changeset),
            else: changeset |> Ecto.Changeset.force_change(:inserted_at, now) |> Repo.insert!()

        rows = replace_environment_repositories!(current, changeset)

        {:changed,
         environment
         |> Map.take(Environment.Changeset.fields() -- [:repositories, :access])
         |> Map.put(:repositories, Enum.map(rows, &elem(&1, 0)))
         |> Map.put(:access, Map.new(rows))
         |> stringify()}
    end
  end

  # The environment's repositories as saved now, the default first:
  # [{ref, access}].
  defp replace_environment_repositories!(current, changeset) do
    ref = Ecto.Changeset.get_field(changeset, :ref)

    case Ecto.Changeset.fetch_change(changeset, :repository_rows) do
      {:ok, rows} ->
        Repo.delete_all(EnvironmentRepository.Query.by_environment(ref))

        Repo.insert_all(
          EnvironmentRepository,
          rows
          |> Enum.with_index()
          |> Enum.map(fn {{repository_ref, access}, position} ->
            %{
              access: access,
              environment_ref: ref,
              position: position,
              repository_ref: repository_ref
            }
          end)
        )

        rows

      :error ->
        if current,
          do: Enum.map(current.repositories, &{&1.repository_ref, &1.access}),
          else: []
    end
  end

  defp delete_item(domain, schema, value, expected_revision, actor_ref) do
    with :ok <- authorize(actor_ref) do
      save(domain, expected_revision, actor_ref, fn snapshot ->
        delete_found(schema, find_item(snapshot, schema, value), snapshot)
      end)
    end
  end

  defp delete_found(schema, nil, _snapshot),
    do: Repo.rollback({:invalid_settings, [{item_key(schema), :unknown}]})

  defp delete_found(schema, item, snapshot) do
    case deletable(item, snapshot) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:invalid_settings, reason})
    end

    Repo.delete!(item)
    {:changed, %{"deleted" => stringify(Map.fetch!(item, item_key(schema)))}}
  end

  @doc """
  Whether `item` may be deleted from `snapshot`: `:ok`, or the error naming
  what still uses it. A repository an environment or a GitHub binding names
  stays; so does an environment a Slack channel or a webhook source selects,
  and an Emisar connection an environment, a session not discarded or an
  approval names.
  """
  @spec deletable(struct(), map()) :: :ok | {:error, keyword()}
  def deletable(%Repository{ref: ref}, snapshot) do
    referenced =
      Enum.any?(snapshot.environments, &(ref in Environment.repository_refs(&1))) or
        Enum.any?(snapshot.github_bindings, &(&1.repository_ref == ref))

    if referenced, do: {:error, [{:ref, :referenced}]}, else: :ok
  end

  def deletable(%Environment{ref: ref}, snapshot) do
    channels = ref |> Environment.Query.selecting_channels() |> Repo.aggregate(:count)
    webhook_sources = Enum.count(snapshot.webhook_sources, &(&1.environment_ref == ref))

    if channels + webhook_sources == 0,
      do: :ok,
      else:
        {:error, [ref: {:referenced, %{channels: channels, webhook_sources: webhook_sources}}]}
  end

  def deletable(%EmisarConnection{ref: ref}, snapshot) do
    environments = Enum.count(snapshot.environments, &(&1.emisar_connection_ref == ref))
    sessions = ref |> Work.Session.Query.using_emisar_connection() |> Repo.aggregate(:count)
    approvals = ref |> Emisar.Approval.Query.by_connection() |> Repo.aggregate(:count)

    if environments + sessions + approvals == 0 do
      :ok
    else
      {:error,
       [
         ref:
           {:referenced, %{approvals: approvals, environments: environments, sessions: sessions}}
       ]}
    end
  end

  def deletable(_item, _snapshot), do: :ok

  # Shared write path ---------------------------------------------------------

  defp save(domain, expected_revision, actor_ref, operation) do
    with :ok <- expected(expected_revision) do
      transaction(fn -> save_locked(domain, expected_revision, actor_ref, operation) end)
    end
  end

  defp save_locked(domain, expected_revision, actor_ref, operation) do
    snapshot = current!(expected_revision)

    case operation.(snapshot) do
      :unchanged ->
        snapshot

      {:changed, values} ->
        record_edit!(snapshot.installation, domain, actor_ref, values)
        fetch!()
    end
  end

  defp expected(:current), do: :ok
  defp expected(revision), do: Validation.revision(revision)

  defp current!(:current) do
    lock!()

    case Repo.one(Installation.Query.all()) do
      nil -> Repo.rollback(:settings_not_initialized)
      %Installation{} = installation -> load(installation)
    end
  end

  defp current!(expected_revision) do
    lock!()

    case Repo.one(Installation.Query.all()) do
      nil ->
        Repo.rollback(:settings_not_initialized)

      %Installation{revision: ^expected_revision} = installation ->
        load(installation)

      %Installation{} = installation ->
        Repo.rollback({:settings_conflict, load(installation)})
    end
  end

  defp record_edit!(installation, domain, actor_ref, values) do
    now = DateTime.utc_now()
    revision = installation.revision + 1

    installation
    |> Ecto.Changeset.change(%{
      revision: revision,
      failure_code: nil,
      saved_by: actor_ref,
      saved_at: now
    })
    |> Repo.update!()

    Repo.insert!(%Edit{
      domain: domain,
      revision: revision,
      actor_ref: actor_ref,
      fingerprint:
        CanonicalJSON.digest(%{
          "domain" => Atom.to_string(domain),
          "values" => stringify(values)
        }),
      inserted_at: now
    })
  end

  defp insert_installation!(host_ref, actor_ref) do
    now = DateTime.utc_now()

    Repo.insert!(%Installation{
      host_ref: host_ref,
      revision: 1,
      applied_revision: 0,
      saved_by: actor_ref,
      saved_at: now,
      inserted_at: now
    })

    Repo.insert!(struct!(Retention, Map.put(@retention_defaults, :id, host_ref)))

    for schema <- [__MODULE__.Slack, GitHub, Publication, Report, Learning, __MODULE__.Work] do
      Repo.insert!(struct!(schema, id: host_ref))
    end

    prices =
      Enum.map(
        Accounting.Pricing.settings_defaults(),
        &Map.merge(&1, %{id: Repo.generate_id(), revision: 1, inserted_at: now})
      )

    Repo.insert_all(PricingRate, prices,
      on_conflict: :nothing,
      conflict_target: [:execution_target, :effective_from]
    )

    Repo.insert!(%Edit{
      domain: :installation,
      revision: 1,
      actor_ref: actor_ref,
      fingerprint: CanonicalJSON.digest(%{"host_ref" => host_ref}),
      inserted_at: now
    })

    fetch!()
  end

  defp load(%Installation{host_ref: host_ref} = installation) do
    %{
      installation: installation,
      retention: Repo.one!(Retention.Query.by_id(host_ref)),
      slack: Repo.one!(__MODULE__.Slack.Query.by_id(host_ref)),
      github: Repo.one!(GitHub.Query.by_id(host_ref)),
      publication: Repo.one!(Publication.Query.by_id(host_ref)),
      emisar_connections:
        Repo.all(EmisarConnection.Query.ordered_by_ref(EmisarConnection.Query.all())),
      report: Repo.one!(Report.Query.by_id(host_ref)),
      learning: Repo.one!(Learning.Query.by_id(host_ref)),
      work: Repo.one!(__MODULE__.Work.Query.by_id(host_ref)),
      repositories: Repo.all(Repository.Query.ordered_by_ref(Repository.Query.all())),
      environments:
        Environment.Query.all()
        |> Environment.Query.ordered_by_ref()
        |> Environment.Query.with_preloaded_repositories()
        |> Repo.all(),
      github_bindings: Repo.all(GitHubBinding.Query.ordered_by_name(GitHubBinding.Query.all())),
      webhook_sources: Repo.all(WebhookSource.Query.ordered_by_name(WebhookSource.Query.all())),
      pricing_rates: Repo.all(PricingRate.Query.ordered_by_target(PricingRate.Query.all()))
    }
  end

  defp generate_host_ref do
    "installation:" <> Crypto.random_hex(32)
  end

  defp lock!, do: AdvisoryLock.hold!(@lock_tag)

  # A committed write is announced after the outermost commit, so a subscriber
  # that reads the revision it heard about finds it. A no-op save announces
  # the revision it left in place; the owner answers that with :unchanged.
  defp transaction(operation) do
    case Repo.transaction(operation) do
      {:ok, %{installation: %Installation{}} = snapshot} ->
        broadcast_settings_saved()
        {:ok, snapshot}

      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Delivers `{:settings_saved, revision}` to the caller after every committed
  write, the revision current once it committed.

  The runtime owner applies a revision when it hears of one. Without this a
  save reached the database and nothing else: it sat pending until the next
  restart, while the settings page said the runtime would pick it up. Several
  writes committed together (`atomically/1`, or any transaction they share)
  are heard once.
  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Ryker.PubSub.subscribe(saves_topic())

  def unsubscribe, do: Ryker.PubSub.unsubscribe(saves_topic())

  @doc """
  Delivers `{:settings_applied, revision}` after the runtime records applying
  a saved revision, or failing to (`record_application/2`), so a page that
  says whether the running system has caught up can say it again.
  """
  @spec subscribe_application() :: :ok | {:error, term()}
  def subscribe_application, do: Ryker.PubSub.subscribe(application_topic())

  def unsubscribe_application, do: Ryker.PubSub.unsubscribe(application_topic())

  defp saves_topic, do: "settings"
  defp application_topic, do: "settings:application"

  # One capture however many writes the transaction made, so the commit is
  # announced once, with the revision it left.
  defp broadcast_settings_saved, do: Repo.after_commit(&broadcast_saved_revision/0)

  defp broadcast_saved_revision do
    case Repo.one(Installation.Query.select_revision()) do
      revision when is_integer(revision) ->
        Ryker.PubSub.broadcast(saves_topic(), {:settings_saved, revision})

      nil ->
        :ok
    end
  end

  defp broadcast_settings_applied(revision) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(application_topic(), {:settings_applied, revision})
    end)
  end

  # The local console is trusted by reach, and so is the person Tailscale Serve
  # or Cloudflare Access named there (`Ryker.ControlPlane.Viewer`). A Slack actor is trusted
  # only when the saved settings let that person manage Ryker: chosen by name, or
  # an admin of the saved workspace while admins may (`Ryker.Slack.Operators`).
  # The payload's own claim of who sent it is never the grant.
  defp authorize(@actor), do: :ok
  defp authorize(@tailnet_actor <> login) when byte_size(login) in 1..200, do: :ok
  defp authorize(@cloudflare_actor <> login) when byte_size(login) in 1..200, do: :ok
  defp authorize("github:webhook"), do: :ok
  defp authorize("github:onboarding"), do: :ok

  defp authorize("slack:user:" <> user_ref) when byte_size(user_ref) in 1..255 do
    saved = Repo.one(__MODULE__.Slack.Query.select_operators())

    with %{chosen: chosen} when is_list(chosen) <- saved,
         operators = Slack.Operators.new(Map.to_list(saved)),
         true <- Slack.Operators.operator?(operators, user_ref) do
      :ok
    else
      _not_an_operator -> {:error, :settings_forbidden}
    end
  end

  defp authorize(_actor), do: {:error, :settings_forbidden}

  defp stringify(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp stringify(%Date{} = value), do: Date.to_iso8601(value)
  defp stringify(%Time{} = value), do: Time.to_iso8601(value)
  defp stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp stringify(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> Map.drop([:__meta__]) |> stringify()

  defp stringify(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  defp stringify(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom),
    do: Atom.to_string(atom)

  defp stringify(value), do: value

  # -- For the console ---------------------------------------------------------

  @doc "How many model targets one kind of work may save."
  @spec most_work_models() :: pos_integer()
  defdelegate most_work_models(), to: Ryker.Settings.Work, as: :most_models

  @doc "How many model accounts Work may save."
  @spec most_work_accounts() :: pos_integer()
  defdelegate most_work_accounts(), to: Ryker.Settings.Work, as: :most_accounts

  @doc "An environment's repositories, its writable one first."
  defdelegate environment_repositories(environment),
    to: Ryker.Settings.Environment,
    as: :repository_refs

  @doc "An environment's repositories that Work may only read."
  defdelegate environment_read_only_repositories(environment),
    to: Ryker.Settings.Environment,
    as: :read_only_refs
end
