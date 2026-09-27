defmodule Ryker.ControlPlane.RepositoryProjection do
  @moduledoc """
  The repository directory: every repository saved settings, an
  environment, a schedule, a session, a publication names, with
  the environments it is in, its counts, its configured work and the freshness receipt of its last recorded work.

  Channels choose environments, not repositories, so a repository's channels
  are the channels whose environment holds it.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{Environments, Search}
  alias Ryker.GitHub.Events
  alias Ryker.Publication.Publication
  alias Ryker.Repo
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
    settings = settings()
    configured = configured_repositories(settings)
    environments = repository_environments(settings)
    channel_counts = Environments.channel_counts()

    channels =
      Map.new(environments, fn {ref, in_environments} ->
        {ref, Enum.sum_by(in_environments, &Map.get(channel_counts, &1.ref, 0))}
      end)

    schedules = grouped_count(Schedule, :repository)
    sessions = grouped_count(Session, :repository_ref)
    publications = grouped_count(Publication, :repository)
    freshness = repository_freshness()

    names =
      [
        Map.keys(configured),
        Map.keys(channels),
        Map.keys(schedules),
        Map.keys(sessions),
        Map.keys(publications),
        Map.keys(freshness)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    names
    |> filter_repository_search(Search.term(params["q"]), configured)
    |> Enum.sort()
    |> Enum.take(@list_limit)
    |> Enum.map(fn repository_ref ->
      %{
        channels: Map.get(channels, repository_ref, 0),
        configured: Map.get(configured, repository_ref),
        environments: environments |> Map.get(repository_ref, []) |> Enum.map(& &1.display_name),
        freshness: Map.get(freshness, repository_ref),
        publications: Map.get(publications, repository_ref, 0),
        ref: repository_ref,
        schedules: Map.get(schedules, repository_ref, 0),
        sessions: Map.get(sessions, repository_ref, 0)
      }
    end)
  end

  def list(_params), do: list(%{})

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

  defp grouped_count(schema, field) do
    Repo.all(
      from(row in schema,
        where: not is_nil(field(row, ^field)),
        group_by: field(row, ^field),
        select: {field(row, ^field), count(row.id)},
        limit: 500
      )
    )
    |> Map.new()
  end

  defp settings do
    case Settings.fetch() do
      {:ok, snapshot} -> snapshot
      _error -> nil
    end
  end

  # The environments that hold each saved repository, in list order.
  defp repository_environments(nil), do: %{}

  defp repository_environments(snapshot) do
    Map.new(snapshot.repositories, &{&1.ref, Environments.containing(snapshot, &1.ref)})
  end

  defp configured_repositories(snapshot) do
    case snapshot do
      %{} ->
        bindings = Map.new(snapshot.github_bindings, &{&1.repository_ref, &1})

        Map.new(snapshot.repositories, fn repository ->
          binding = Map.get(bindings, repository.ref)

          {repository.ref,
           %{
             action_grants: binding && binding.action_grants,
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

      nil ->
        %{}
    end
  end

  defp repository_freshness do
    Repo.all(
      from(turn in Turn,
        join: session in Session,
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
    )
    |> Enum.reduce(%{}, &put_repository_freshness/2)
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
