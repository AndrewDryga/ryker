defmodule Ryker.GitHubActions.IssueTriage do
  @moduledoc "Current-input authority for read-only triage and additive label permission."
  alias Ryker.CanonicalJSON
  alias Ryker.GitHub
  alias Ryker.GitHubActions.{IssueRequest, IssueTriageRead, IssueTriageTools, IssueWorkflow}
  alias Ryker.GitHubActions.IssueWorkflows
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.StateTools

  def call(name, arguments, binding, client) do
    with :ok <- StateTools.SchemaCheck.exact_schema(name, arguments, IssueTriageTools.list()),
         :ok <- input_size(name, arguments),
         {:ok, authorized} <- authority(binding, arguments["instruction_ref"], client),
         do: perform(name, arguments, binding, client, authorized)
  end

  defp input_size("complete_github_issue_triage", arguments) do
    brief = Map.drop(arguments, ~w(instruction_ref plan))
    plan = arguments["plan"] || ""

    if byte_size(CanonicalJSON.encode!(brief)) <= 8000 and byte_size(plan) <= 16_000,
      do: :ok,
      else: {:error, :triage_result_too_large}
  end

  defp input_size(_name, _arguments), do: :ok

  defp authority(binding, reference, client) do
    with {:ok, {entry, _event}} <- Records.TaskInstruction.fetch_source(binding, reference),
         {:ok, %IssueRequest{kind: :triage_issue} = request} <-
           Repo.fetch(IssueRequest.Query.by_entry_id(entry.id)),
         {:ok, workflow} <- Repo.fetch(IssueWorkflow.Query.by_id(request.workflow_id)),
         true <-
           not is_nil(request.outcome) or
             (workflow.current_request_id == request.id and
                workflow.revision == request.base_revision),
         {:ok, configured} <- GitHub.IssueIndex.configuration(workflow.binding_ref),
         true <-
           configured.binding.repository_id == workflow.repository_id and
             configured.binding.installation_id == workflow.installation_id and
             configured.repository.ref == workflow.repository_ref,
         true <-
           client.repository_id == workflow.repository_id and
             client.repository_full_name == configured.repository.github_repository,
         true <- request.actor_id > 0 or configured.repository.github_issue_triage,
         :ok <- GitHub.IssueTriageGrant.check_entry(entry) do
      {:ok, %{request: request, workflow: workflow, configured: configured, entry: entry}}
    else
      _denied -> {:error, :triage_request_required}
    end
  end

  defp perform("prepare_github_issue_triage", _arguments, _binding, client, authorized) do
    with {:ok, document, _issue} <- current_issue(client, authorized),
         {:ok, related} <-
           GitHub.IssueIndex.search(authorized.configured, document["issue"]["title"]) do
      labels =
        case GitHub.Client.IssueTriage.labels(client.client, client.repository_full_name) do
          {:ok, labels} -> labels
          {:error, _unavailable} -> %{"names" => [], "coverage" => "unavailable"}
        end

      {:ok,
       %{
         "current" => document,
         "related" => related,
         "labels" => labels,
         "auto_labels" => authorized.configured.repository.github_triage_labels
       }}
    end
  end

  defp perform("read_related_github_issue", arguments, binding, client, authorized) do
    with :ok <-
           GitHub.Client.IssueTriage.repository(
             client.client,
             client.repository_full_name,
             authorized.workflow.repository_id
           ),
         {:ok, document} <-
           GitHub.Client.IssueTriage.read(
             client.client,
             client.repository_full_name,
             arguments["number"]
           ) do
      record_read(
        binding,
        authorized,
        Map.put(document, "url", issue_url(authorized, arguments["number"]))
      )
    end
  end

  defp perform("complete_github_issue_triage", arguments, binding, client, authorized) do
    result = Map.delete(arguments, "instruction_ref")
    fingerprint = CanonicalJSON.digest(result)

    case authorized.request.outcome do
      %{"triage" => %{"fingerprint" => ^fingerprint}} = outcome -> {:ok, outcome}
      %{} -> {:error, :triage_already_saved}
      nil -> complete(arguments, result, fingerprint, binding, client, authorized)
    end
  end

  defp record_read(binding, authorized, document) do
    Repo.transaction(fn ->
      :ok = Records.TaskInstruction.lock_source(authorized.entry)

      case StateTools.Binding.fetch_and_lock_current_with_episode(binding) do
        {:ok, _current} -> record_read_locked!(authorized, document)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp record_read_locked!(authorized, document) do
    workflow =
      authorized.workflow.id
      |> IssueWorkflow.Query.by_id()
      |> IssueWorkflow.Query.lock_for_update()
      |> Repo.fetch!()

    if workflow.current_request_id != authorized.request.id,
      do: Repo.rollback(:triage_request_changed)

    fingerprint = read_fingerprint(document)
    reads = authorized.request.id |> IssueTriageRead.Query.by_request_id() |> Repo.all()
    read = Enum.find(reads, &(&1.fingerprint == fingerprint))
    if is_nil(read) and length(reads) >= 8, do: Repo.rollback(:triage_read_limit)

    read =
      read ||
        IssueTriageRead.Changeset.insert(%{
          request_id: authorized.request.id,
          number: document["issue"]["number"],
          fingerprint: fingerprint,
          document: document,
          inserted_at: Repo.now!()
        })
        |> Repo.insert!()

    Map.put(document, "read_id", read.id)
  end

  defp read_fingerprint(document),
    do: document |> Map.drop(~w(observed_at url read_id)) |> CanonicalJSON.digest()

  defp complete(arguments, result, fingerprint, binding, client, authorized) do
    with {:ok, _document, _issue} <- current_issue(client, authorized),
         {:ok, related} <- related_results(result["related"], client, authorized),
         :ok <- valid_labels(result["labels"], client) do
      saved = result |> Map.put("related", related) |> Map.put("fingerprint", fingerprint)

      Repo.transaction(fn ->
        complete_locked!(arguments["instruction_ref"], saved, binding, client, authorized)
      end)
    end
  end

  defp complete_locked!(reference, saved, binding, client, authorized) do
    :ok = Settings.synchronize_in_transaction()
    :ok = Records.TaskInstruction.lock_source(authorized.entry)

    with {:ok, current} <- StateTools.Binding.fetch_and_lock_current_with_episode(binding),
         true <- current.episode.execution_mode == :live,
         true <- get_in(current.turn.validation_intent || %{}, ["verdict"]) != "accept",
         {:ok, fresh} <- authority(binding, reference, client),
         {:ok, _document, _issue} <- current_issue(client, fresh) do
      status = apply_labels(saved["labels"], client, fresh)

      case IssueWorkflows.save_triage(binding, reference, Map.put(saved, "labels_status", status)) do
        {:ok, outcome} -> outcome
        {:error, reason} -> Repo.rollback(reason)
      end
    else
      _changed -> Repo.rollback(:triage_request_changed)
    end
  end

  defp current_issue(client, authorized) do
    with :ok <-
           GitHub.Client.IssueTriage.repository(
             client.client,
             client.repository_full_name,
             authorized.workflow.repository_id
           ),
         {:ok, document} <-
           GitHub.Client.IssueTriage.read(
             client.client,
             client.repository_full_name,
             authorized.workflow.number
           ),
         {:ok, issue} <-
           GitHub.IssueSnapshot.prepare(
             authorized.configured,
             authorized.workflow.number,
             document["issue"]
           ),
         true <- not document["issue"]["body_truncated"],
         true <-
           GitHub.IssueSnapshot.content_digest(issue) ==
             GitHub.IssueSnapshot.content_digest(authorized.request.source_snapshot["issue"]) do
      {:ok, document, issue}
    else
      _changed -> {:error, :issue_changed}
    end
  end

  defp related_results(related, client, authorized) do
    Enum.reduce_while(related, {:ok, []}, fn item, {:ok, acc} ->
      case related_result(item, client, authorized) do
        {:ok, saved} -> {:cont, {:ok, acc ++ [saved]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp related_result(item, client, authorized) do
    with false <- item["number"] == authorized.workflow.number,
         {:ok, document} <-
           GitHub.Client.IssueTriage.read(
             client.client,
             client.repository_full_name,
             item["number"]
           ),
         {:ok, read} <-
           Repo.fetch(
             IssueTriageRead.Query.by_request_id(authorized.request.id)
             |> IssueTriageRead.Query.by_fingerprint(read_fingerprint(document))
           ) do
      {:ok,
       item
       |> Map.put("url", issue_url(authorized, item["number"]))
       |> Map.put("observed", %{
         "title" => String.byte_slice(document["issue"]["title"], 0, 200),
         "updated_at" => document["issue"]["updated_at"],
         "digest" => read.fingerprint,
         "read_id" => read.id
       })}
    else
      true -> {:error, :invalid_related_issue}
      {:error, :not_found} -> {:error, :related_issue_not_read}
      {:error, _unavailable} -> {:error, :related_issue_unavailable}
    end
  end

  defp valid_labels([], _client), do: :ok

  defp valid_labels(labels, client) do
    case GitHub.Client.IssueTriage.labels(client.client, client.repository_full_name) do
      {:ok, %{"names" => names}} ->
        if Enum.all?(labels, &(&1 in names)), do: :ok, else: {:error, :unknown_triage_label}

      {:error, _unavailable} ->
        {:error, :triage_labels_unavailable}
    end
  end

  defp apply_labels([], _client, _authorized), do: "No labels suggested."

  defp apply_labels(_labels, _client, %{configured: %{repository: %{github_triage_labels: false}}}),
       do: "Suggested only; automatic labels are off."

  defp apply_labels(labels, client, authorized) do
    case GitHub.Client.IssueTriage.add_existing_labels(
           client.triage_client,
           client.repository_full_name,
           authorized.workflow.number,
           labels
         ) do
      :ok ->
        "Applied. Existing labels were kept."

      {:error, _unavailable} ->
        "Could not confirm all labels were applied; check the issue's labels."
    end
  end

  defp issue_url(authorized, number) do
    "#{GitHub.web_url(authorized.configured.settings.github.api_url)}/#{authorized.configured.repository.github_repository}/issues/#{number}"
  end
end
