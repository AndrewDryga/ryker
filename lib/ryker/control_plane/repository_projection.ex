defmodule Ryker.ControlPlane.RepositoryProjection do
  @moduledoc """
  The repository directory: every repository added to Ryker, with the
  environments it is in, its counts, its configured work, the freshness
  receipt of its last recorded work, and where its knowledge stands
  (`Ryker.RepositoryKnowledge`).

  Channels choose environments, not repositories, so a repository's channels
  are the channels whose environment holds it.
  """

  import Ecto.Query

  alias Ryker.Accounting.Execution
  alias Ryker.ControlPlane.{CallRun, Environments, Search}
  alias Ryker.GitHub.Events
  alias Ryker.InspectionRedactor, as: Redactor
  alias Ryker.Publication.Publication
  alias Ryker.{Repo, RepositoryKnowledge}
  alias Ryker.Schedules.Schedule
  alias Ryker.Settings
  alias Ryker.Work.{Session, Turn}

  @list_limit 100

  @doc "Every repository added to Ryker, with its environments, counts, configured work and freshness."
  def list(params) when is_map(params) do
    parts = parts(:all)

    parts
    |> refs()
    |> filter_repository_search(Search.term(params["q"]), parts.configured)
    |> Enum.sort()
    |> Enum.take(@list_limit)
    |> Enum.map(&row(&1, parts))
  end

  def list(_params), do: list(%{})

  @doc """
  One repository's row as `list/1` shows it, read for its exact ref alone, or
  `:error` when it is not added. The questions a row's buttons ask read it
  this way, so a repository past the list's first hundred is still found.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(ref) when is_binary(ref) do
    parts = parts({:ref, ref})
    if ref in refs(parts), do: {:ok, row(ref, parts)}, else: :error
  end

  @doc """
  One repository's page: its row as `fetch/1` reads it, and the model runs
  that wrote its knowledge.
  """
  @spec detail(String.t()) :: {:ok, map()} | :error
  def detail(ref) when is_binary(ref) do
    with {:ok, row} <- fetch(ref), do: {:ok, Map.put(row, :knowledge_runs, knowledge_runs(ref))}
  end

  @knowledge_runs 5

  # The model runs that wrote this repository's knowledge, newest first, with
  # what each cost from the execution ledger and exactly what it was sent and
  # answered (Andrew, 2026-09-28: every model call shows the prompt it was
  # sent; the knowledge runs were shown nowhere).
  defp knowledge_runs(ref) do
    runs =
      Repo.all(
        from(run in RepositoryKnowledge.Run,
          where: run.repository_ref == ^ref,
          order_by: [desc: run.inserted_at, desc: run.id],
          limit: @knowledge_runs
        )
      )

    ids = Enum.map(runs, & &1.id)

    executions =
      Repo.all(from(e in Execution, where: e.kind == "knowledge" and e.source_id in ^ids))
      |> Map.new(&{&1.source_id, &1})

    secrets = Redactor.configured_secrets()

    Enum.map(runs, fn run ->
      call = CallRun.from_background(run, executions[run.id])

      %{
        id: run.id,
        at: run.started_at || run.inserted_at,
        status: run.status,
        commit: run.source_commit,
        target: call.target,
        tokens: call.tokens,
        cost: call.cost,
        total_ms: call.total_ms,
        error_code: run.error_code,
        dropped: run.dropped_count,
        prompt: exact(run.prompt, secrets),
        result: exact(run.result, secrets)
      }
    end)
  end

  # The bytes as they were sent or answered. Re-encoding the JSON would
  # reorder it into something never sent; the redactor keeps the format.
  defp exact(nil, _secrets), do: nil

  defp exact(text, secrets) do
    case Redactor.artifact(text, secrets: secrets, preserve_format: true, max_bytes: 2_097_152) do
      %{state: :retained, text: text} -> text
      _unavailable -> nil
    end
  end

  # What rows are built from, by repository ref: every repository's, or one
  # ref's alone.
  defp parts(scope) do
    settings = settings()
    saved = saved_repositories(settings, scope)
    environments = repository_environments(settings, saved)
    channel_counts = Environments.channel_counts()

    %{
      channels:
        Map.new(environments, fn {ref, in_environments} ->
          {ref, Enum.sum_by(in_environments, &Map.get(channel_counts, &1.ref, 0))}
        end),
      configured: configured_repositories(settings, saved),
      environments: environments,
      freshness: repository_freshness(scope),
      knowledge: knowledge(scope),
      publications: grouped_count(Publication, :repository, scope),
      schedules: grouped_count(Schedule, :repository, scope),
      # The tasks people asked for: a session that read the repository for its
      # RYKER.md is none of them.
      sessions:
        grouped_count(
          from(session in Session, where: session.execution_kind == :work),
          :repository_ref,
          scope
        )
    }
  end

  # The repositories Ryker has. One removed from Ryker leaves the list, and
  # its tasks keep their history (Andrew, 2026-09-28).
  defp refs(parts), do: Map.keys(parts.configured)

  defp row(repository_ref, parts) do
    %{
      channels: Map.get(parts.channels, repository_ref, 0),
      configured: Map.get(parts.configured, repository_ref),
      environments:
        parts.environments |> Map.get(repository_ref, []) |> Enum.map(& &1.display_name),
      in_environments:
        parts.environments
        |> Map.get(repository_ref, [])
        |> Enum.map(&%{ref: &1.ref, name: &1.display_name}),
      freshness: Map.get(parts.freshness, repository_ref),
      knowledge: knowledge_view(Map.get(parts.knowledge, repository_ref)),
      publications: Map.get(parts.publications, repository_ref, 0),
      ref: repository_ref,
      schedules: Map.get(parts.schedules, repository_ref, 0),
      sessions: Map.get(parts.sessions, repository_ref, 0)
    }
  end

  defp knowledge(:all), do: RepositoryKnowledge.entries()

  defp knowledge({:ref, ref}) do
    case RepositoryKnowledge.entry(ref) do
      nil -> %{}
      entry -> %{ref => entry}
    end
  end

  # What a row says of the repository's knowledge: what is under way, the
  # document Ryker keeps and who wrote it, why the last step failed, and when
  # the next check is due. Ryker is the only place the document can be read.
  defp knowledge_view(nil), do: nil

  defp knowledge_view(entry) do
    Map.take(entry, [
      :phase,
      :reason,
      :document,
      :document_by,
      :document_commit,
      :document_at,
      :checked_at,
      :next_check_at,
      :error
    ])
  end

  defp filter_repository_search(names, nil, _configured), do: names

  defp filter_repository_search(names, search, configured) do
    search = String.downcase(search)

    Enum.filter(names, fn ref ->
      Enum.any?(
        [ref, get_in(configured, [ref, :github_repository])],
        &(is_binary(&1) and String.contains?(String.downcase(&1), search))
      )
    end)
  end

  defp grouped_count(schema, field, scope) do
    query =
      from(row in schema,
        where: not is_nil(field(row, ^field)),
        group_by: field(row, ^field),
        select: {field(row, ^field), count(row.id)},
        limit: 500
      )

    query =
      case scope do
        :all -> query
        {:ref, ref} -> where(query, [row], field(row, ^field) == ^ref)
      end

    query |> Repo.all() |> Map.new()
  end

  defp settings do
    case Settings.fetch() do
      {:ok, snapshot} -> snapshot
      _error -> nil
    end
  end

  # The saved repositories a read covers: every one, or the one it asks about.
  defp saved_repositories(nil, _scope), do: []
  defp saved_repositories(snapshot, :all), do: snapshot.repositories

  defp saved_repositories(snapshot, {:ref, ref}),
    do: Enum.filter(snapshot.repositories, &(&1.ref == ref))

  # The environments that hold each saved repository, in list order.
  defp repository_environments(nil, _saved), do: %{}

  defp repository_environments(snapshot, saved),
    do: Map.new(saved, &{&1.ref, Environments.containing(snapshot, &1.ref)})

  defp configured_repositories(nil, _saved), do: %{}

  defp configured_repositories(snapshot, saved) do
    bindings = Map.new(snapshot.github_bindings, &{&1.repository_ref, &1})

    Map.new(saved, fn repository ->
      binding = Map.get(bindings, repository.ref)

      {repository.ref,
       %{
         action_grants: binding && binding.action_grants,
         # Saved without it, a repository is not fully added: nothing
         # can set it up or work in it (`RepositoriesPage`).
         github_bound: not is_nil(binding),
         github_permissions: binding && binding.granted_permissions,
         github_access: repository.github_access,
         github_health: binding && Events.health(binding.name),
         github_repository: repository.github_repository,
         onboarding_error: repository.onboarding_error,
         onboarding_state: repository.onboarding_state,
         ref: repository.ref,
         source_commit: repository.source_commit,
         updated_at: repository.updated_at
       }}
    end)
  end

  defp repository_freshness(scope) do
    query =
      from(turn in Turn,
        join: session in Session,
        as: :session,
        on: session.id == turn.session_id,
        where: not is_nil(session.repository_ref) and not is_nil(turn.submission),
        order_by: [desc: turn.updated_at, desc: turn.id],
        limit: 500,
        select: %{
          recorded_at: turn.updated_at,
          repository_ref: session.repository_ref,
          submission: turn.submission
        }
      )

    query =
      case scope do
        :all -> query
        {:ref, ref} -> where(query, [session: session], session.repository_ref == ^ref)
      end

    query |> Repo.all() |> Enum.reduce(%{}, &put_repository_freshness/2)
  end

  defp put_repository_freshness(row, found) do
    case {Map.has_key?(found, row.repository_ref), primary_freshness(row.submission)} do
      {true, _freshness} ->
        found

      {false, nil} ->
        found

      {false, freshness} ->
        Map.put(found, row.repository_ref, Map.put(freshness, :recorded_at, row.recorded_at))
    end
  end

  defp primary_freshness(submission) when is_map(submission) do
    with %{"owner" => "coop", "repositories" => repositories, "status" => "recorded"} <-
           get_in(submission, ["context", "workspace", "freshness"]),
         true <- is_list(repositories),
         %{} = receipt <- Enum.find(repositories, &(&1["name"] == "primary")) do
      %{
        fetched_at: receipt["fetched_at"],
        remote_identity: receipt["remote_identity"],
        requested_revision: receipt["requested_revision"],
        resolved_revision: receipt["resolved_revision"],
        stale_base_revision: receipt["stale_base_revision"],
        stale_base_status: receipt["stale_base_status"],
        version: receipt["version"],
        workspace_base_revision: receipt["workspace_base_revision"]
      }
    else
      _missing -> nil
    end
  end

  defp primary_freshness(_submission), do: nil
end
