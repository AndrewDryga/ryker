defmodule Ryker.ControlPlane.RepositoryProjection do
  @moduledoc """
  The repository directory: every repository saved settings, an
  environment, a schedule, a session, a publication names, with
  the environments it is in, its counts, its configured work, the freshness
  receipt of its last recorded work, and where its RYKER.md stands
  (`Ryker.RepositoryKnowledge`).

  Channels choose environments, not repositories, so a repository's channels
  are the channels whose environment holds it.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{Environments, Search}
  alias Ryker.GitHub.Events
  alias Ryker.Publication.Publication
  alias Ryker.{Repo, RepositoryKnowledge}
  alias Ryker.Schedules.Schedule
  alias Ryker.Settings
  alias Ryker.Work.{Session, Turn}

  @list_limit 100

  @doc """
  The name people know each added repository by, `owner/repo`, keyed by its
  ref. A ref with no saved repository is its own name.
  """
  @spec names() :: %{String.t() => String.t()}
  def names do
    Repo.all(
      from(repository in Settings.Repository,
        select: {repository.ref, coalesce(repository.github_repository, repository.display_name)}
      )
    )
    |> Map.new(fn {ref, name} -> {ref, name || ref} end)
  end

  @doc "Every repository anything names, with its environments, counts, configured work and freshness."
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
  `:error` when nothing names it. The questions a row's buttons ask read it
  this way, so a repository past the list's first hundred is still found.
  """
  @spec fetch(String.t()) :: {:ok, map()} | :error
  def fetch(ref) when is_binary(ref) do
    parts = parts({:ref, ref})
    if ref in refs(parts), do: {:ok, row(ref, parts)}, else: :error
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

  # Every ref anything names.
  defp refs(parts) do
    [
      parts.configured,
      parts.channels,
      parts.schedules,
      parts.sessions,
      parts.publications,
      parts.freshness
    ]
    |> Enum.flat_map(&Map.keys/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp row(repository_ref, parts) do
    %{
      channels: Map.get(parts.channels, repository_ref, 0),
      configured: Map.get(parts.configured, repository_ref),
      environments:
        parts.environments |> Map.get(repository_ref, []) |> Enum.map(& &1.display_name),
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

  # What a row says of RYKER.md: what is under way, the last document Ryker
  # wrote and its pull request, why the last step failed, and when the next
  # check is due. The document itself stays in the database.
  defp knowledge_view(nil), do: nil

  defp knowledge_view(entry) do
    Map.take(entry, [
      :phase,
      :reason,
      :document_by,
      :document_commit,
      :document_at,
      :published_at,
      :publication,
      :pull_request_url,
      :pull_request_number,
      :pull_request_state,
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
         knowledge_sha256: repository.knowledge_sha256,
         knowledge_source_commit: repository.knowledge_source_commit,
         knowledge_status: repository.knowledge_status,
         knowledge_pull_request_url: repository.knowledge_pull_request_url,
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
