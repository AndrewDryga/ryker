defmodule Ryker.GitHub.CIRepairSignals do
  @moduledoc "Verified GitHub signals select candidate PRs; fresh reads decide every repair."
  alias Ryker.Config
  alias Ryker.GitHub.{Binding, CIRepairs, Client}
  alias Ryker.GitObject
  alias Ryker.Publication
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Work

  def observe(binding, event, payload) do
    with :ok <- Binding.authorize_payload(binding, payload) do
      signal(binding, event, payload)
    end
  end

  defp signal(binding, "pull_request", %{
         "action" => action,
         "label" => %{"name" => "ryker:no-ci-fix"},
         "pull_request" => pull
       })
       when action in ["labeled", "unlabeled"] do
    nudge(
      binding,
      [pull["number"]],
      get_in(pull, ["head", "sha"]),
      action == "unlabeled"
    )
  end

  defp signal(binding, "pull_request", %{"action" => action, "pull_request" => pull})
       when action in ["opened", "reopened", "synchronize", "closed"],
       do: nudge(binding, [pull["number"]], get_in(pull, ["head", "sha"]), false)

  defp signal(binding, event, %{"action" => "completed"} = payload)
       when event in ["check_run", "check_suite", "workflow_run", "workflow_job"] do
    subject = payload[event] || %{}
    checks(binding, subject["head_sha"], subject["pull_requests"] || [])
  end

  defp signal(binding, "status", %{"sha" => sha}), do: checks(binding, sha, [])
  defp signal(_binding, _event, _payload), do: :ok

  defp checks(binding, sha, pulls) do
    with true <- GitObject.id?(sha),
         {:ok, configured} <- CIRepairs.configuration(binding.name),
         true <- configured.repository.github_ci_repair != :off do
      with {:ok, numbers} <- numbers(binding, sha, pulls),
           do: nudge(binding, numbers, sha, false)
    else
      _ignored -> :ok
    end
  end

  defp numbers(_binding, _sha, [_first | _rest] = pulls) when length(pulls) <= 20 do
    numbers =
      Enum.map(pulls, fn
        %{"number" => number} -> number
        _invalid -> nil
      end)

    if Enum.all?(numbers, &(is_integer(&1) and &1 > 0)),
      do: {:ok, numbers},
      else: {:error, :invalid_ci_repair_signal}
  end

  defp numbers(binding, sha, []) do
    runtime = Config.get_env(:github) || %{}

    case get_in(runtime, [:ci_repairs, :bindings, binding.name]) do
      %{read_client: client} ->
        Client.CIRepair.associated(client, binding.repository_full_name, sha)

      _unavailable ->
        {:error, :ci_repair_unavailable}
    end
  end

  defp numbers(_binding, _sha, _pulls), do: {:error, :invalid_ci_repair_signal}

  defp nudge(binding, numbers, sha, refresh) do
    if Enum.all?(numbers, &(is_integer(&1) and &1 > 0)) do
      Enum.reduce_while(Enum.uniq(numbers), :ok, &enqueue(&1, binding, sha, refresh, &2))
    else
      {:error, :invalid_ci_repair_signal}
    end
  end

  defp enqueue(number, binding, sha, refresh, :ok) do
    case CIRepairs.nudge(binding, number, sha, refresh) do
      {:ok, _queued} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @doc "The existing own-PR poller uses the same policy as webhook-triggered repairs."
  def observe_lifecycle(event_ref) do
    with {:ok, %{kind: :checks, state: state} = event} <-
           Repo.fetch(Publication.LifecycleEvent.Query.by_ref(event_ref)),
         true <- state in [:failed, :succeeded],
         {:ok, publication} <-
           Repo.fetch(Publication.Publication.Query.by_id(event.publication_id)),
         {:ok, settings} <- Settings.fetch(),
         binding when not is_nil(binding) <-
           Enum.find(settings.github_bindings, &(&1.repository_ref == publication.repository)),
         {:ok, session} <- Repo.fetch(Work.Session.Query.by_id(publication.session_id)),
         source when is_map(source) <- get_in(session.worker_job_document || %{}, ["source"]),
         true <- source["github_repository_id"] == binding.repository_id,
         true <- source["github_repository"] == publication.github_repository do
      expected = Map.put(binding, :repository_full_name, publication.github_repository)
      nudge(expected, [publication.pull_request_number], publication.commit_sha, false)
    else
      _other -> :ok
    end
  end
end
