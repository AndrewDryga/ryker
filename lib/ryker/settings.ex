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

  import Ecto.Query

  alias Ryker.Accounting.Pricing
  alias Ryker.CanonicalJSON
  alias Ryker.Repo

  alias Ryker.Settings.{
    Edit,
    EmisarConnection,
    Environment,
    EnvironmentRepository,
    GitHub,
    GitHubBinding,
    Installation,
    Learning,
    PricingRate,
    Publication,
    Report,
    Repository,
    Retention,
    RetentionImpact,
    Slack,
    Validation,
    WebhookSource,
    Work
  }

  alias Ryker.Slack.Operators

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
  @type snapshot :: %{
          installation: Installation.t(),
          retention: Retention.t(),
          slack: Slack.t(),
          work: Work.t(),
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

  @doc "The current consistent snapshot, or an explicit not-initialized error."
  @spec fetch() :: {:ok, snapshot()} | {:error, :settings_not_initialized}
  def fetch do
    case Repo.one(Installation) do
      nil -> {:error, :settings_not_initialized}
      %Installation{} = installation -> {:ok, load(installation)}
    end
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
  def slack_workspace_url, do: Repo.one(from(slack in Slack, select: slack.workspace_url))

  @doc """
  The enrolled worker workspace Work runs in, or nil when none is selected.

  The recovery surfaces ask this once per blocked row; loading the whole
  settings snapshot for one string would make a failures page pay fourteen
  queries a row for it.
  """
  @spec worker_workspace_ref() :: String.t() | nil
  def worker_workspace_ref, do: Repo.one(from(work in Work, select: work.workspace_ref))

  @doc "Creates the single installation identity and typed defaults exactly once."
  def initialize(actor_ref) do
    with :ok <- authorize(actor_ref) do
      transaction(fn -> initialize_locked(actor_ref) end)
    end
  end

  defp initialize_locked(actor_ref) do
    # The lock fences simultaneous first saves so they agree on one identity.
    lock!()

    case Repo.one(Installation) do
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

    case Repo.one(Installation) do
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

  defp shortened?(:routing_examples_seconds, current, proposed),
    do:
      current.routing_examples_enabled and
        proposed.routing_examples_seconds < current.routing_examples_seconds

  defp shortened?(:work_examples_enabled, current, proposed),
    do: current.work_examples_enabled and not proposed.work_examples_enabled

  defp shortened?(:work_examples_seconds, current, proposed),
    do:
      current.work_examples_enabled and
        proposed.work_examples_seconds < current.work_examples_seconds

  defp shortened?(field, current, proposed),
    do: Map.fetch!(proposed, field) < Map.fetch!(current, field)

  defp retention_confirmation(proposed, revision) do
    CanonicalJSON.digest(%{"revision" => revision, "retention" => stringify(proposed)})
  end

  # Singleton domains ---------------------------------------------------------

  def save_slack(attributes, expected_revision, actor_ref),
    do: save_singleton(:slack, Slack, attributes, expected_revision, actor_ref)

  def save_github(attributes, expected_revision, actor_ref),
    do: save_singleton(:github, GitHub, attributes, expected_revision, actor_ref)

  def save_publication(attributes, expected_revision, actor_ref),
    do: save_singleton(:publication, Publication, attributes, expected_revision, actor_ref)

  def save_report(attributes, expected_revision, actor_ref),
    do: save_singleton(:report, Report, attributes, expected_revision, actor_ref)

  def save_learning(attributes, expected_revision, actor_ref),
    do: save_singleton(:learning, Learning, attributes, expected_revision, actor_ref)

  def save_work(attributes, expected_revision, actor_ref),
    do: save_singleton(:work, Work, attributes, expected_revision, actor_ref)

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
          Slack.changeset(snapshot.slack, %{default_participation: value}, snapshot)
        )
      end)
    end
  end

  def save_default_participation(_value, _actor_ref),
    do: {:error, {:invalid_settings, [{:default_participation, :inclusion}]}}

  defp save_singleton(domain, schema, attributes, expected_revision, actor_ref) do
    with :ok <- authorize(actor_ref),
         {:ok, attributes} <- Validation.attributes(attributes, schema.fields()) do
      save(domain, expected_revision, actor_ref, fn snapshot ->
        current = Map.fetch!(snapshot, domain)
        write_changeset(current, schema.changeset(current, attributes, snapshot))
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
    do: put_item(:repositories, Repository, :ref, attributes, expected_revision, actor_ref)

  @doc """
  Saves a change to a repository that is still added, at whatever revision
  the settings are at: a step of Ryker's own, such as setup, never conflicts
  with a person's save. A removed repository stays removed
  (`{:error, :repository_removed}`).
  """
  def update_repository(ref, attributes, actor_ref) when is_binary(ref) do
    with :ok <- authorize(actor_ref),
         {:ok, attributes} <-
           Validation.attributes(Map.put(attributes, :ref, ref), Repository.fields()) do
      save(:repositories, :current, actor_ref, &update_found_repository(&1, ref, attributes))
    end
  end

  defp update_found_repository(snapshot, ref, attributes) do
    case Repository.find(snapshot, :ref, ref) do
      nil -> Repo.rollback(:repository_removed)
      current -> write_changeset(current, Repository.changeset(current, attributes, snapshot))
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
        repository = Repository.find(snapshot, :ref, ref)
        deleted = delete_found(Repository, :ref, repository, snapshot)
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
  def put_environment(attributes, expected_revision, actor_ref) do
    with :ok <- authorize(actor_ref),
         {:ok, attributes} <- Validation.attributes(attributes, Environment.fields()) do
      save(:environments, expected_revision, actor_ref, fn snapshot ->
        current = Environment.find(snapshot, :ref, Map.get(attributes, :ref))

        changeset =
          Environment.changeset(current || Environment.new(snapshot), attributes, snapshot)

        write_environment(current, changeset)
      end)
    end
  end

  def delete_environment(ref, expected_revision, actor_ref),
    do: delete_item(:environments, Environment, :ref, ref, expected_revision, actor_ref)

  def put_emisar_connection(attributes, expected_revision, actor_ref),
    do:
      put_item(
        :emisar,
        EmisarConnection,
        :ref,
        attributes,
        expected_revision,
        actor_ref
      )

  def delete_emisar_connection(ref, expected_revision, actor_ref) do
    with {:ok, snapshot} <-
           delete_item(
             :emisar,
             EmisarConnection,
             :ref,
             ref,
             expected_revision,
             actor_ref
           ),
         {:ok, :ok} <- Ryker.Credentials.delete(:emisar, ref, actor_ref) do
      {:ok, snapshot}
    end
  end

  def put_github_binding(attributes, expected_revision, actor_ref),
    do: put_item(:github, GitHubBinding, :name, attributes, expected_revision, actor_ref)

  def delete_github_binding(name, expected_revision, actor_ref),
    do: delete_item(:github, GitHubBinding, :name, name, expected_revision, actor_ref)

  def put_webhook_source(attributes, expected_revision, actor_ref),
    do: put_item(:webhooks, WebhookSource, :name, attributes, expected_revision, actor_ref)

  def delete_webhook_source(name, expected_revision, actor_ref),
    do: delete_item(:webhooks, WebhookSource, :name, name, expected_revision, actor_ref)

  def put_pricing_rate(attributes, expected_revision, actor_ref),
    do: put_item(:pricing, PricingRate, :id, attributes, expected_revision, actor_ref)

  def delete_pricing_rate(id, expected_revision, actor_ref),
    do: delete_item(:pricing, PricingRate, :id, id, expected_revision, actor_ref)

  defp put_item(domain, schema, key, attributes, expected_revision, actor_ref) do
    with :ok <- authorize(actor_ref),
         {:ok, attributes} <- Validation.attributes(attributes, schema.fields()) do
      save(domain, expected_revision, actor_ref, fn snapshot ->
        current = schema.find(snapshot, key, Map.get(attributes, key))
        changeset = schema.changeset(current || schema.new(snapshot), attributes, snapshot)
        write_changeset(current, changeset)
      end)
    end
  end

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
          Repo.update_all(
            from(environment in Environment,
              where: environment.is_default and environment.ref != ^ref
            ),
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
         |> Map.take(Environment.fields() -- [:repositories, :access])
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
        Repo.delete_all(from(row in EnvironmentRepository, where: row.environment_ref == ^ref))

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

  defp delete_item(domain, schema, key, value, expected_revision, actor_ref) do
    with :ok <- authorize(actor_ref) do
      save(domain, expected_revision, actor_ref, fn snapshot ->
        delete_found(schema, key, schema.find(snapshot, key, value), snapshot)
      end)
    end
  end

  defp delete_found(_schema, key, nil, _snapshot),
    do: Repo.rollback({:invalid_settings, [{key, :unknown}]})

  defp delete_found(schema, key, item, snapshot) do
    case schema.deletable(item, snapshot) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:invalid_settings, reason})
    end

    Repo.delete!(item)
    {:changed, %{"deleted" => stringify(Map.get(item, key))}}
  end

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

    case Repo.one(Installation) do
      nil -> Repo.rollback(:settings_not_initialized)
      %Installation{} = installation -> load(installation)
    end
  end

  defp current!(expected_revision) do
    lock!()

    case Repo.one(Installation) do
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
      id: Ecto.UUID.generate(),
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

    for schema <- [Slack, GitHub, Publication, Report, Learning, Work] do
      Repo.insert!(struct!(schema, id: host_ref))
    end

    for attributes <- Pricing.settings_defaults() do
      Repo.insert!(
        struct!(
          PricingRate,
          attributes
          |> Map.put(:id, Ecto.UUID.generate())
          |> Map.put(:revision, 1)
          |> Map.put(:inserted_at, now)
        ),
        on_conflict: :nothing,
        conflict_target: [:execution_target, :effective_from]
      )
    end

    Repo.insert!(%Edit{
      id: Ecto.UUID.generate(),
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
      retention: Repo.get!(Retention, host_ref),
      slack: Repo.get!(Slack, host_ref),
      github: Repo.get!(GitHub, host_ref),
      publication: Repo.get!(Publication, host_ref),
      emisar_connections: Repo.all(from(c in EmisarConnection, order_by: c.ref)),
      report: Repo.get!(Report, host_ref),
      learning: Repo.get!(Learning, host_ref),
      work: Repo.get!(Work, host_ref),
      repositories: Repo.all(from(r in Repository, order_by: r.ref)),
      environments: Repo.all(from(e in Environment, order_by: e.ref, preload: :repositories)),
      github_bindings: Repo.all(from(b in GitHubBinding, order_by: b.name)),
      webhook_sources: Repo.all(from(w in WebhookSource, order_by: w.name)),
      pricing_rates:
        Repo.all(from(p in PricingRate, order_by: [p.execution_target, p.effective_from]))
    }
  end

  defp generate_host_ref do
    "installation:" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end

  defp lock! do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [@lock_tag])
  end

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
  defp broadcast_settings_saved, do: Repo.after_commit(&announce_saved_revision/0)

  defp announce_saved_revision do
    case Repo.one(from(installation in Installation, select: installation.revision)) do
      revision when is_integer(revision) ->
        Ryker.PubSub.broadcast(saves_topic(), {:settings_saved, revision})

      nil ->
        :ok
    end
  end

  defp broadcast_settings_applied(revision),
    do:
      Repo.after_commit(fn ->
        Ryker.PubSub.broadcast(application_topic(), {:settings_applied, revision})
      end)

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
    saved =
      Repo.one(
        from(slack in Slack,
          select: %{
            chosen: slack.operators,
            workspace_admins: slack.workspace_admins_manage,
            workspace_ref: slack.workspace_ref
          }
        )
      )

    with %{chosen: chosen} when is_list(chosen) <- saved,
         true <- saved |> Map.to_list() |> Operators.new() |> Operators.operator?(user_ref) do
      :ok
    else
      _not_an_operator -> {:error, :settings_forbidden}
    end
  end

  defp authorize(_actor), do: {:error, :settings_forbidden}

  @doc false
  def stringify(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  def stringify(%Date{} = value), do: Date.to_iso8601(value)
  def stringify(%Time{} = value), do: Time.to_iso8601(value)
  def stringify(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def stringify(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> Map.drop([:__meta__]) |> stringify()

  def stringify(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)

  def stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)

  def stringify(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom),
    do: Atom.to_string(atom)

  def stringify(value), do: value
end
