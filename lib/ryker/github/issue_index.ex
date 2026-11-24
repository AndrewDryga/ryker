defmodule Ryker.GitHub.IssueIndex do
  @moduledoc "Repository-scoped, bounded issue retrieval with durable refresh and triage intent."
  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.Embeddings
  alias Ryker.GitHub.{IndexedIssue, IssueIndexState, IssueTriageGrant}
  alias Ryker.Lease
  alias Ryker.Repo
  alias Ryker.Settings

  def configuration(name) do
    with {:ok, settings} <- Settings.fetch(),
         true <- settings.github.enabled,
         binding when not is_nil(binding) <-
           Enum.find(settings.github_bindings, &(&1.name == name)),
         %{github_access: :available} = repository <-
           Enum.find(settings.repositories, &(&1.ref == binding.repository_ref)) do
      {:ok, %{settings: settings, binding: binding, repository: repository}}
    else
      _unavailable -> {:error, :repository_access_changed}
    end
  end

  def ensure(configured) do
    Repo.transaction(fn ->
      fence!(configured)
      ensure_locked!(configured)
    end)
  end

  @doc "Only verified webhook ingress calls this. Backfill never requests triage."
  def signal(binding, event, %{"issue" => issue} = payload, check)
      when event in ["issues", "issue_comment"] do
    with true <-
           is_nil(issue["pull_request"]) and is_integer(issue["number"]) and issue["number"] > 0,
         {:ok, configured} <- configuration(binding.name),
         true <-
           configured.binding.repository_id == binding.repository_id and
             configured.binding.installation_id == binding.installation_id,
         true <- configured.repository.github_issue_triage,
         {:ok, grant} <- IssueTriageGrant.new(payload),
         :ok <- IssueTriageGrant.authorize(grant, binding, check) do
      triage =
        event == "issues" and payload["action"] in ["opened", "reopened", "edited"] and
          issue["state"] == "open"

      case enqueue(configured, issue["number"], triage, grant) do
        {:ok, _issue} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, {:github_repository_access_unavailable, reason}} ->
        {:error, {:github_repository_access_unavailable, reason}}

      _disabled ->
        :ok
    end
  end

  def signal(_binding, _event, _payload, _check), do: :ok

  def enqueue(configured, number, triage, grant) do
    Repo.transaction(fn ->
      fence!(configured)
      index = ensure_locked!(configured)
      issue = enqueue_locked!(index, number, triage, grant)
      update_index!(index, %{next_attempt_at: Repo.now!()})
      issue
    end)
  end

  def claim_next(bindings) do
    Repo.transaction(fn ->
      case Repo.fetch(IssueIndexState.Query.next_claimable(Repo.now!(), bindings)) do
        {:error, :not_found} ->
          nil

        {:ok, index} ->
          update_index!(index, %{
            lease_ref: Repo.generate_id(),
            lease_expires_at: DateTime.add(Repo.now!(), 120)
          })
      end
    end)
  end

  def fetch_next_issue(%IssueIndexState{} = index) do
    index.id
    |> IndexedIssue.Query.by_index_id()
    |> IndexedIssue.Query.next_pending(Repo.now!())
    |> Repo.fetch()
  end

  def backfilled(%IssueIndexState{} = claimed, configured, page) do
    Repo.transaction(fn ->
      fence!(configured)
      index = locked_claim!(claimed)
      Enum.each(page.numbers, &enqueue_locked!(index, &1, false, nil))

      update_index!(index, %{
        page: index.page + 1,
        backfill_complete: page.complete,
        next_attempt_at: Repo.now!(),
        lease_ref: nil,
        lease_expires_at: nil
      })
    end)
  end

  @doc "A refresh started before an edit cannot clear that edit's pending work."
  def refreshed(
        %IssueIndexState{} = claimed,
        %IndexedIssue{} = issue,
        configured,
        document,
        embedding
      ) do
    Repo.transaction(fn ->
      fence!(configured)
      index = locked_claim!(claimed)

      current =
        index.id
        |> IndexedIssue.Query.by_index_id()
        |> IndexedIssue.Query.by_number(issue.number)
        |> IndexedIssue.Query.lock_for_update()
        |> Repo.fetch!()

      if current.generation != issue.generation, do: Repo.rollback(:issue_index_changed)
      {model, vector} = embedding

      current
      |> IndexedIssue.Changeset.update(%{
        document: document,
        embedding_model: model,
        embedding: vector
      })
      |> Repo.update!()
    end)
  end

  def settled(
        %IssueIndexState{} = claimed,
        %IndexedIssue{} = issue,
        configured,
        digest,
        retry_seconds \\ nil
      ) do
    Repo.transaction(fn ->
      fence!(configured)
      index = locked_claim!(claimed)

      current =
        index.id
        |> IndexedIssue.Query.by_index_id()
        |> IndexedIssue.Query.by_number(issue.number)
        |> IndexedIssue.Query.lock_for_update()
        |> Repo.fetch!()

      if current.generation == issue.generation do
        current
        |> IndexedIssue.Changeset.update(%{
          pending: not is_nil(retry_seconds),
          triage_pending: not is_nil(retry_seconds) and current.triage_pending,
          last_triaged_digest: digest || current.last_triaged_digest,
          next_attempt_at: if(retry_seconds, do: DateTime.add(Repo.now!(), retry_seconds))
        })
        |> Repo.update!()
      end

      update_index!(index, %{next_attempt_at: Repo.now!(), lease_ref: nil, lease_expires_at: nil})
    end)
  end

  def release(%IssueIndexState{} = claimed, seconds) do
    Repo.transaction(fn ->
      index = locked_claim!(claimed)

      update_index!(index, %{
        next_attempt_at: DateTime.add(Repo.now!(), seconds),
        lease_ref: nil,
        lease_expires_at: nil
      })
    end)
  end

  def embedding(document, options \\ []) do
    text = Jason.encode!(document)

    case Embeddings.embed([text], options) do
      {:ok, [vector]} -> {Keyword.get(options, :model, Embeddings.model()), vector}
      {:error, _unavailable} -> {nil, nil}
    end
  end

  @doc "Search is evidence to inspect, never proof that no duplicate exists."
  def search(configured, text, options \\ []) do
    with {:ok, index} <- ensure(configured) do
      {model, vector} = embedding(%{"query" => text}, options)

      rows =
        index.id
        |> IndexedIssue.Query.by_index_id()
        |> IndexedIssue.Query.search(text, model || "", vector || [])
        |> Repo.all()

      matches =
        for {issue, keyword, meaning} <- rows,
            keyword > 0 or (is_number(meaning) and meaning >= 0.55),
            do: issue.document

      {:ok,
       %{
         "items" => matches,
         "coverage" => "partial",
         "backfill_complete" => index.backfill_complete,
         "note" =>
           "Bounded cached titles, bodies and up to 20 comments. Refresh likely matches before concluding they are duplicates; an empty search does not prove none exist.",
         "meaning_search" => not is_nil(vector)
       }}
    end
  end

  defp ensure_locked!(configured) do
    identity =
      CanonicalJSON.digest(%{
        "binding" => configured.binding.name,
        "repository" => configured.binding.repository_id,
        "installation" => configured.binding.installation_id
      })

    AdvisoryLock.hold!("issue-index:" <> identity)

    case Repo.fetch(
           IssueIndexState.Query.by_identity(identity)
           |> IssueIndexState.Query.lock_for_update()
         ) do
      {:ok, index} ->
        index

      {:error, :not_found} ->
        IssueIndexState.Changeset.insert(%{
          identity: identity,
          binding_ref: configured.binding.name,
          repository_ref: configured.repository.ref,
          repository_id: configured.binding.repository_id,
          installation_id: configured.binding.installation_id,
          next_attempt_at: Repo.now!()
        })
        |> Repo.insert!()
    end
  end

  defp enqueue_locked!(index, number, triage, grant) do
    query = index.id |> IndexedIssue.Query.by_index_id() |> IndexedIssue.Query.by_number(number)

    case Repo.fetch(query |> IndexedIssue.Query.lock_for_update()) do
      {:ok, issue} when is_nil(grant) ->
        issue

      {:ok, issue} ->
        keep =
          not triage and issue.pending and issue.triage_pending and
            get_in(issue.event_grant, ["digest"]) == grant["digest"]

        issue
        |> IndexedIssue.Changeset.update(%{
          generation: issue.generation + 1,
          pending: true,
          triage_pending: triage or keep,
          event_grant: if(keep, do: issue.event_grant, else: grant),
          next_attempt_at: Repo.now!()
        })
        |> Repo.update!()

      {:error, :not_found} ->
        IndexedIssue.Changeset.insert(%{
          index_id: index.id,
          number: number,
          event_grant: grant,
          triage_pending: triage,
          next_attempt_at: Repo.now!()
        })
        |> Repo.insert!()
    end
  end

  defp fence!(configured) do
    :ok = Settings.synchronize_in_transaction()

    with {:ok, current} <- configuration(configured.binding.name),
         true <-
           current.binding.repository_id == configured.binding.repository_id and
             current.binding.installation_id == configured.binding.installation_id and
             current.repository.ref == configured.repository.ref and
             current.repository.github_repository == configured.repository.github_repository and
             current.repository.github_issue_triage == configured.repository.github_issue_triage,
         do: :ok,
         else: (_changed -> Repo.rollback(:repository_access_changed))
  end

  defp locked_claim!(claimed) do
    index =
      claimed.id
      |> IssueIndexState.Query.by_id()
      |> IssueIndexState.Query.lock_for_update()
      |> Repo.fetch!()

    if Lease.held?(index, claimed.lease_ref, Repo.now!()),
      do: index,
      else: Repo.rollback(:issue_index_lease_lost)
  end

  defp update_index!(index, attributes),
    do: index |> IssueIndexState.Changeset.update(attributes) |> Repo.update!()
end
