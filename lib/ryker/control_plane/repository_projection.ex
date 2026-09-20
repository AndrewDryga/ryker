defmodule Ryker.ControlPlane.RepositoryProjection do
  @moduledoc """
  The repository directory: every repository the runtime configuration, a
  channel, a schedule, a session, a publication or a worker names, with its
  counts, its policies, the workers that hold it and the freshness receipt of
  its last recorded work.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.Search
  alias Ryker.CoopFleet.Worker
  alias Ryker.GitHub.Events
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack.ChannelConfiguration
  alias Ryker.State.Schedule
  alias Ryker.Work.{Session, Turn}

  @list_limit 100

  @doc "Every repository anything names, with its counts, policies, workers and freshness."
  def list(params) when is_map(params) do
    runtime = runtime_repositories()
    channels = grouped_count(ChannelConfiguration, :repository_ref)
    schedules = grouped_count(Schedule, :repository)
    sessions = grouped_count(Session, :repository_ref)
    publications = grouped_count(Publication, :repository)
    workers = repository_workers()
    freshness = repository_freshness()

    names =
      [
        Map.keys(runtime),
        Map.keys(channels),
        Map.keys(schedules),
        Map.keys(sessions),
        Map.keys(publications),
        Map.keys(workers),
        Map.keys(freshness)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    names
    |> filter_repository_search(Search.term(params["q"]))
    |> Enum.sort()
    |> Enum.take(@list_limit)
    |> Enum.map(fn repository_ref ->
      %{
        channels: Map.get(channels, repository_ref, 0),
        configured: Map.get(runtime, repository_ref),
        freshness: Map.get(freshness, repository_ref),
        publications: Map.get(publications, repository_ref, 0),
        ref: repository_ref,
        schedules: Map.get(schedules, repository_ref, 0),
        sessions: Map.get(sessions, repository_ref, 0),
        workers: Map.get(workers, repository_ref, [])
      }
    end)
  end

  def list(_params), do: list(%{})

  defp filter_repository_search(names, nil), do: names

  defp filter_repository_search(names, search) do
    search = String.downcase(search)
    Enum.filter(names, &String.contains?(String.downcase(&1), search))
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

  defp runtime_repositories do
    control_plane = Application.get_env(:ryker, :control_plane, %{})
    schedules = Application.get_env(:ryker, :schedules, %{})

    task_policies =
      control_plane
      |> safe_map(:task_policies)
      |> Enum.map(fn {ref, policy} ->
        {to_string(ref), %{contributor_policy: safe_policy_name(policy)}}
      end)

    schedule_policies =
      schedules
      |> safe_map(:repositories)
      |> Enum.map(fn {ref, policy} ->
        {to_string(ref), %{schedule_policy: safe_policy_name(policy)}}
      end)

    configured =
      Enum.reduce(task_policies ++ schedule_policies, %{}, fn {ref, value}, found ->
        Map.update(found, ref, value, &Map.merge(&1, value))
      end)

    saved =
      case Settings.fetch() do
        {:ok, snapshot} ->
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
               source_commit: repository.source_commit
             }}
          end)

        _error ->
          %{}
      end

    Map.merge(saved, configured, fn _ref, durable, runtime -> Map.merge(durable, runtime) end)
  end

  defp repository_workers do
    Repo.all(
      from(worker in Worker,
        where: worker.state in [:eligible, :busy, :draining],
        order_by: [asc: worker.id],
        limit: 200,
        select: %{
          id: worker.id,
          last_seen_at: worker.last_seen_at,
          repositories: worker.repositories,
          state: worker.state
        }
      )
    )
    |> Enum.reduce(%{}, fn worker, found ->
      worker.repositories
      |> List.wrap()
      |> Enum.reduce(found, fn
        %{"ref" => ref} = repository, acc when is_binary(ref) ->
          item = %{
            revision: Map.get(repository, "revision"),
            state: worker.state,
            worker_ref: worker.id,
            last_seen_at: worker.last_seen_at
          }

          Map.update(acc, ref, [item], &[item | &1])

        _invalid, acc ->
          acc
      end)
    end)
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

  defp safe_map(value, key) when is_map(value) do
    case Map.get(value, key, %{}) do
      map when is_map(map) -> map
      _other -> %{}
    end
  end

  defp safe_map(_value, _key), do: %{}

  defp safe_policy_name(%{name: name}) when is_binary(name), do: name
  defp safe_policy_name(%{"name" => name}) when is_binary(name), do: name
  defp safe_policy_name(_unknown), do: "configured"
end
