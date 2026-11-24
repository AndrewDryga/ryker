defmodule Ryker.GitHub.IssueTriageGrant do
  @moduledoc "The two writers and exact report revision behind an automatic GitHub issue read."
  alias Ryker.CanonicalJSON
  alias Ryker.Config
  alias Ryker.GitHub
  alias Ryker.GitHub.{Binding, IssueIndex, IssueSnapshot}
  alias Ryker.GitHubActions
  alias Ryker.Repo

  def new(%{"sender" => sender, "issue" => issue}) do
    with {:ok, sender} <- human(sender),
         {:ok, author} <- human(issue["user"]),
         {:ok, digest} <- digest(issue) do
      {:ok, %{"sender" => sender, "author" => author, "digest" => digest}}
    end
  end

  def new(_payload), do: {:error, :actor_not_authorized}

  def authorize(%{"author" => author, "sender" => sender}, binding, check) do
    [sender, author]
    |> Enum.uniq()
    |> Enum.reduce_while(:ok, fn actor, :ok ->
      case check.(binding, %{"sender" => actor}) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def authorize(_missing, _binding, _check), do: {:error, :actor_not_authorized}

  def matches?(%{"digest" => expected}, issue), do: digest(issue) == {:ok, expected}
  def matches?(_missing, _issue), do: false

  # Recheck deferred system work before either paid lane submits it. Historical
  # requests have no grant and cannot acquire one from a later edit or setting.
  def check_entry(%{execution_mode: :live, actor_ref: "system:github-issue-triage"} = entry) do
    with {:ok, request} <- Repo.fetch(GitHubActions.IssueRequest.Query.by_entry_id(entry.id)) do
      case recheck(entry, request) do
        {:error, reason}
        when reason in [
               :triage_request_changed,
               :actor_not_authorized,
               :repository_access_changed
             ] ->
          GitHubActions.IssueWorkflows.expire_automatic(request)
          {:error, :triage_request_expired}

        other ->
          other
      end
    end
  end

  def check_entry(_other), do: :ok

  defp recheck(_entry, %{outcome: %{"status" => "authorization_expired"}}),
    do: {:error, :triage_request_expired}

  defp recheck(entry, request) do
    runtime = Config.get_env(:github) || %{}
    grant = request.source_snapshot["triage_grant"]
    issue = request.source_snapshot["issue"]

    with true <- is_map(grant),
         {:ok, configured} <- IssueIndex.configuration(entry.source_ref),
         true <- configured.repository.github_issue_triage,
         %{binding: binding, check: check, read_client: client} <-
           get_in(runtime, [:issue_triage, :bindings, entry.source_ref]),
         true <-
           configured.binding.installation_id == binding.installation_id and
             configured.binding.repository_id == binding.repository_id,
         :ok <- Binding.authorize_payload(binding, entry.content["payload"]),
         :ok <- authorize(grant, binding, check),
         {:ok, current} <- IssueSnapshot.fetch_current(configured, issue["number"], client),
         true <- matches?(grant, current) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      nil -> {:error, :github_runtime_unavailable}
      _changed -> {:error, :triage_request_changed}
    end
  end

  defp human(%{"id" => id, "login" => login, "type" => "User"} = actor) do
    if GitHub.id?(id) and GitHub.login?(login),
      do: {:ok, Map.take(actor, ~w(id login type))},
      else: {:error, :actor_not_authorized}
  end

  defp human(_actor), do: {:error, :actor_not_authorized}

  defp digest(%{"id" => id, "number" => number, "title" => title} = issue)
       when is_integer(id) and is_integer(number) and is_binary(title) do
    {:ok, CanonicalJSON.digest([id, number, title, issue["body"] || ""])}
  end

  defp digest(_missing), do: {:error, :issue_changed}
end
