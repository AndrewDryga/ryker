defmodule Ryker.GitHubActions.Requests do
  @moduledoc "Freezes an authenticated action as one durable GitHub instruction."
  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.Config
  alias Ryker.GitHub
  alias Ryker.Ingress
  alias Ryker.Repo
  alias Ryker.Settings

  @doc "Reuses the original receipt across repeated clicks and process restarts."
  def record(access, number, kind, request, evidence) do
    event_ref = event_ref(access, number, kind, evidence["request_key"])

    with {:ok, binding} <- placement(access) do
      Repo.transaction(fn ->
        record_locked(access, binding, number, kind, request, evidence, event_ref)
      end)
    end
  end

  @doc "Finds a previous click before checking whether its completed work changed the PR."
  def fetch(access, number, kind, request_key) do
    reference = event_ref(access, number, kind, request_key)

    case Repo.fetch(Ingress.Inbox.Entry.Query.by_source_event("github", reference)) do
      {:ok, entry} -> {:ok, %{entry: entry, status: :duplicate}}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp event_ref(access, number, kind, key) do
    identity = %{
      "binding" => access.binding.name,
      "actor" => access.actor["id"],
      "number" => number,
      "kind" => kind,
      "request_key" => key
    }

    "github-action:" <> CanonicalJSON.digest(identity)
  end

  defp record_locked(access, binding, number, kind, request, evidence, event_ref) do
    AdvisoryLock.hold!(event_ref)

    with :ok <- Settings.synchronize_in_transaction(),
         :ok <- unchanged_settings(access),
         {:ok, receipt} <-
           find_or_insert(access, binding, number, kind, request, evidence, event_ref),
         do: receipt,
         else: ({:error, reason} -> Repo.rollback(reason))
  end

  defp find_or_insert(access, binding, number, kind, request, evidence, event_ref) do
    case Repo.fetch(Ingress.Inbox.Entry.Query.by_source_event("github", event_ref)) do
      {:ok, entry} -> {:ok, %{entry: entry, status: :duplicate}}
      {:error, :not_found} -> insert(access, binding, number, kind, request, evidence, event_ref)
    end
  end

  defp insert(access, binding, number, kind, request, evidence, event_ref) do
    now = Repo.now!()

    payload = %{
      "installation" => %{"id" => binding.installation_id},
      "repository" => %{
        "id" => binding.repository_id,
        "full_name" => binding.repository_full_name
      },
      "sender" => access.actor,
      "action" => kind
    }

    subject = if kind == "fix_review", do: "pull", else: "issue"

    with {:ok, input} <-
           Ingress.Input.new(%{
             actor: input_actor(access, kind),
             content: %{
               "event_name" => "ryker_action",
               "request" => request,
               "payload" => payload,
               "action_evidence" => evidence
             },
             destination: %{
               transport: "github",
               conversation_ref: "github:#{binding.name}:repository:#{binding.repository_id}",
               thread_ref: "github:#{binding.name}:#{subject}:#{number}"
             },
             event_kind: :message,
             event_ref: event_ref,
             native_input_id: event_ref,
             source: %{kind: "github", ref: binding.name},
             source_capabilities: %{},
             source_item_ref: event_ref,
             occurred_at: now,
             occurred_at_source: :ingress,
             revision: 1
           }) do
      Ingress.Inbox.record(input,
        work_profile: binding.work_profile,
        engagement_receipt: %{"reason" => "repository_action", "actor" => access.actor["login"]}
      )
    end
  end

  defp input_actor(%{actor: %{"id" => 0}}, "triage_issue"),
    do: %{kind: :system, ref: "system:github-issue-triage"}

  defp input_actor(access, _kind),
    do: %{kind: :user, ref: "github-user:#{access.actor["id"]}"}

  defp placement(access) do
    runtime = Config.get_env(:github) || %{}
    binding = get_in(runtime, [:server, :bindings, access.binding.name])

    case binding do
      %GitHub.Binding{work_profile: %Ingress.WorkProfile{}} ->
        if binding.repository_id == access.binding.repository_id and
             binding.installation_id == access.binding.installation_id,
           do: {:ok, binding},
           else: {:error, :repository_work_not_ready}

      _missing ->
        {:error, :repository_work_not_ready}
    end
  end

  defp unchanged_settings(access) do
    with {:ok, current} <- Settings.fetch(),
         true <-
           GitHub.TaskAccess.authority_configuration(current) ==
             GitHub.TaskAccess.authority_configuration(access.settings),
         do: :ok,
         else: (_changed -> {:error, :repository_access_changed})
  end
end
