defmodule Ryker.Settings do
  @moduledoc """
  Typed durable product settings behind one installation identity.

  Every domain row is edited through the same write path: the caller is the
  authenticated local settings boundary, the expected global revision must
  match under a transaction lock, the typed changeset must validate as a whole,
  a normalized no-op costs nothing, and every real change records an edit
  receipt with a content fingerprint. A failed database read is never an
  absent setting: only a missing installation row means "not initialized",
  and a database that already holds product history refuses fresh defaults
  because a new identity would re-key worker, delivery and publication custody.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Repo

  alias Ryker.Settings.{
    Edit,
    Emisar,
    GitHub,
    GitHubBinding,
    Installation,
    Learning,
    PolicyBinding,
    PricingRate,
    Publication,
    Report,
    Repository,
    RepositoryContext,
    Retention,
    RetentionImpact,
    Slack,
    Validation,
    WebhookSource,
    Work
  }

  @actor "control-plane:local"
  @lock_tag "ryker-settings"
  @day 86_400
  @retention_defaults %{
    operational_data_seconds: 30 * @day,
    conversation_memory_seconds: 90 * @day,
    closed_work_seconds: 30 * @day,
    episode_history_seconds: 30 * @day,
    audit_data_seconds: 30 * @day
  }
  @retention_fields Map.keys(@retention_defaults)
  @application_failures [
    :assembly_failed,
    :invalid_credentials,
    :missing_credentials,
    :runtime_start_failed,
    :secret_unavailable,
    :worker_gateway_unavailable
  ]
  # Tables whose rows only exist once the product ran: their presence means an
  # existing installation whose identity must be imported, not re-keyed.
  @retained_state_tables ~w(
    model_instruction_settings
    slack_channel_configurations
    slack_channel_setting_overrides
    slack_channel_memberships
    coop_workers
    episode_kernel_episodes
    ingress_inbox_entries
    episode_schedules
    operator_behaviors
    operational_memory_entries
    episode_publications
    slack_incident_rooms
  )

  @type snapshot :: %{
          installation: Installation.t(),
          retention: Retention.t(),
          slack: Slack.t(),
          work: Work.t(),
          github: GitHub.t(),
          publication: Publication.t(),
          emisar: Emisar.t(),
          report: Report.t(),
          learning: Learning.t(),
          repositories: [Repository.t()],
          contexts: [RepositoryContext.t()],
          github_bindings: [GitHubBinding.t()],
          policy_bindings: [PolicyBinding.t()],
          webhook_sources: [WebhookSource.t()],
          pricing_rates: [PricingRate.t()]
        }

  def actor, do: @actor
  def application_failures, do: @application_failures
  def retention_defaults, do: @retention_defaults

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
  @spec work_workspace_ref() :: String.t() | nil
  def work_workspace_ref, do: Repo.one(from(work in Work, select: work.workspace_ref))

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
      %Installation{} = installation ->
        load(installation)

      nil ->
        if retained_state?(), do: Repo.rollback(:settings_import_required)
        insert_installation!(generate_host_ref(), actor_ref, %{})
    end
  end

  @doc """
  Creates the installation with an imported identity and imported domain values.

  Only the explicit importer calls this: it is the one path that may create the
  root row while retained product history exists, because it carries the exact
  host identity that history was keyed under.
  """
  def import_installation(host_ref, actor_ref, domains) when is_map(domains) do
    with :ok <- authorize(actor_ref),
         :ok <- Validation.host_ref(host_ref) do
      transaction(fn -> import_installation_locked(host_ref, actor_ref, domains) end)
    end
  end

  defp import_installation_locked(host_ref, actor_ref, domains) do
    lock!()

    case Repo.one(Installation) do
      %Installation{} -> Repo.rollback(:settings_already_initialized)
      nil -> insert_installation!(host_ref, actor_ref, domains)
    end
  end

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
      :ok
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
    |> Enum.filter(&(Map.fetch!(proposed, &1) < Map.fetch!(current, &1)))
    |> Enum.sort()
  end

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

  def save_emisar(attributes, expected_revision, actor_ref),
    do: save_singleton(:emisar, Emisar, attributes, expected_revision, actor_ref)

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

  def delete_repository(ref, expected_revision, actor_ref),
    do: delete_item(:repositories, Repository, :ref, ref, expected_revision, actor_ref)

  def put_repository_context(attributes, expected_revision, actor_ref),
    do: put_item(:repositories, RepositoryContext, :ref, attributes, expected_revision, actor_ref)

  def delete_repository_context(ref, expected_revision, actor_ref),
    do: delete_item(:repositories, RepositoryContext, :ref, ref, expected_revision, actor_ref)

  def put_github_binding(attributes, expected_revision, actor_ref),
    do: put_item(:github, GitHubBinding, :name, attributes, expected_revision, actor_ref)

  def delete_github_binding(name, expected_revision, actor_ref),
    do: delete_item(:github, GitHubBinding, :name, name, expected_revision, actor_ref)

  def put_policy_binding(attributes, expected_revision, actor_ref),
    do: put_item(:policies, PolicyBinding, :id, attributes, expected_revision, actor_ref)

  def delete_policy_binding(id, expected_revision, actor_ref),
    do: delete_item(:policies, PolicyBinding, :id, id, expected_revision, actor_ref)

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

  defp insert_installation!(host_ref, actor_ref, domains) do
    now = DateTime.utc_now()

    Repo.insert!(%Installation{
      host_ref: host_ref,
      revision: 1,
      applied_revision: 0,
      saved_by: actor_ref,
      saved_at: now,
      inserted_at: now
    })

    Repo.insert!(
      struct!(
        Retention,
        Map.put(Map.get(domains, :retention, @retention_defaults), :id, host_ref)
      )
    )

    for {schema, key} <- [
          {Slack, :slack},
          {GitHub, :github},
          {Publication, :publication},
          {Emisar, :emisar},
          {Report, :report},
          {Learning, :learning},
          {Work, :work}
        ] do
      Repo.insert!(struct!(schema, Map.put(Map.get(domains, key, %{}), :id, host_ref)))
    end

    Repo.insert!(%Edit{
      id: Ecto.UUID.generate(),
      domain: if(map_size(domains) == 0, do: :installation, else: :import),
      revision: 1,
      actor_ref: actor_ref,
      fingerprint:
        CanonicalJSON.digest(%{"host_ref" => host_ref, "domains" => stringify(domains)}),
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
      emisar: Repo.get!(Emisar, host_ref),
      report: Repo.get!(Report, host_ref),
      learning: Repo.get!(Learning, host_ref),
      work: Repo.get!(Work, host_ref),
      repositories: Repo.all(from(r in Repository, order_by: r.ref)),
      contexts: Repo.all(from(c in RepositoryContext, order_by: c.ref)),
      github_bindings: Repo.all(from(b in GitHubBinding, order_by: b.name)),
      policy_bindings:
        Repo.all(from(p in PolicyBinding, order_by: [p.scope_kind, p.scope_ref, p.purpose])),
      webhook_sources: Repo.all(from(w in WebhookSource, order_by: w.name)),
      pricing_rates:
        Repo.all(from(p in PricingRate, order_by: [p.execution_target, p.effective_from]))
    }
  end

  defp retained_state? do
    Enum.any?(@retained_state_tables, fn table ->
      %{rows: [[present]]} = Repo.query!("SELECT EXISTS (SELECT 1 FROM #{table} LIMIT 1)")
      present
    end)
  end

  defp generate_host_ref do
    "installation:" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end

  defp lock! do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [@lock_tag])
  end

  defp transaction(operation) do
    case Repo.transaction(operation) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # The local console is trusted by reach. A Slack actor is trusted only when
  # the saved operator membership already names it; the payload's own claim of
  # who sent it is never the grant.
  defp authorize(@actor), do: :ok

  defp authorize("slack:user:" <> user_ref) when byte_size(user_ref) in 1..255 do
    case Repo.one(from(slack in Slack, select: slack.operators)) do
      operators when is_list(operators) ->
        if user_ref in operators, do: :ok, else: {:error, :settings_forbidden}

      nil ->
        {:error, :settings_forbidden}
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
