defmodule Ryker.Memories.Cases do
  @moduledoc """
  Durable custody for completed cases.

  Everything Ryker learned from an incident used to expire with the raw
  transcript that produced it, so a matching outage a year later started from
  nothing. A case is captured from the episode's own retained evidence before
  that evidence is eligible for cleanup, keeps no raw payload, and outlives
  the transcript: it goes only when a message it was built from is taken
  back or its channel is deleted.

  Capture is idempotent by content: repeated close, reopen, cleanup and
  restart events update one case per intended revision instead of appending a
  new one, so nothing here can become a loop that feeds on its own output.
  Deletion is explicit and redacts the text while keeping the identity, so a
  deleted case cannot be reconstructed from a summary that quoted it.

  A person taking back a message the work was built from, by deleting it or
  editing it to say something else, withdraws the case as Ryker receives the
  change (`withdraw_message_in_transaction/1`), whether the case was already
  kept or the work is still running. Deleting a Slack channel withdraws every
  case built from its messages the same way
  (`withdraw_conversation_in_transaction/2`).
  """
  alias Ryker.CanonicalJSON
  alias Ryker.Continuity
  alias Ryker.Episodes
  alias Ryker.Memories.{CaseRecord, MemorySearchPage}
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work

  @problem_bytes 4_096
  @cause_bytes 4_096
  @outcome_bytes 4_096
  @search_bytes 16_384
  @maximum_actions 32
  # One checked source can be four and a half kilobytes, and thirty-two made a
  # case larger than a search answer may hold (2026-10-04 review).
  @action_bytes 1_024
  @actions_bytes 16_384
  # The row holds 64 (episode_case_record_valid); more raised inside history
  # retention, which then stopped on the same episode every pass.
  @maximum_occurrences 64
  @maximum_links 32
  @maximum_anchors 64
  @terminal_states [:complete, :cancelled]
  @recall_limit 5
  @redacted "(deleted)"

  @doc """
  Captures or refreshes the compact case for each finished episode.

  Retention calls this before the raw episode rows become eligible for
  cleanup, so the useful part of an incident never disappears at the history
  horizon.
  """
  @spec capture_many([Ecto.UUID.t()]) :: non_neg_integer()
  def capture_many([]), do: 0

  # In episode order, the order a withdrawal takes the cases of the work a
  # message joined in, so the two never wait on each other's cases.
  def capture_many(episode_ids) do
    episode_ids
    |> Enum.sort()
    |> Enum.map(&capture/1)
    |> Enum.count(&match?({:ok, _case}, &1))
  end

  @doc "Captures one finished episode; unfinished work has no case yet."
  @spec capture(Ecto.UUID.t()) :: {:ok, CaseRecord.t()} | {:error, term()}
  def capture(episode_id) do
    case Repo.fetch(Episodes.Episode.Query.by_id(episode_id)) do
      {:ok, %Episodes.Episode{state: state} = episode} when state in @terminal_states ->
        persist(episode)

      {:ok, %Episodes.Episode{}} ->
        {:error, :case_episode_active}

      {:error, :not_found} ->
        {:error, :case_episode_not_found}
    end
  end

  @doc """
  Related retained cases for one episode, newest evidence first.

  This is recall, never authority: a historical fix is advice about what
  worked once, not proof that this incident has the same cause.
  """
  @spec recall(Episodes.Episode.t(), pos_integer()) :: [map()]
  def recall(%Episodes.Episode{} = episode, limit \\ @recall_limit) do
    terms = Episodes.RoutingDigests.search_terms(digest_text(episode))

    with false <- terms == "",
         {:ok, scope} <- Continuity.Scope.destination_context(episode, nil) do
      scope
      |> CaseRecord.Query.recallable(episode.execution_mode)
      |> CaseRecord.Query.excluding_episode(episode.id)
      |> CaseRecord.Query.matching_terms(terms)
      |> CaseRecord.Query.limit_to(limit)
      |> Repo.all()
      |> Enum.map(&document/1)
    else
      _nothing_to_recall -> []
    end
  end

  @doc "One `search_memory` page over the retained cases `episode` may see."
  @spec search_page(Episodes.Episode.t(), String.t() | nil, map()) :: {:ok, map(), list()} | :done
  def search_page(%Episodes.Episode{} = episode, repository_ref, page) do
    case Continuity.Scope.destination_context(episode, repository_ref) do
      {:ok, scope} ->
        fields = CaseRecord.Query.search_fields()

        scope
        |> CaseRecord.Query.recallable(episode.execution_mode)
        |> CaseRecord.Query.within_scope(scope, page.scope)
        |> MemorySearchPage.one(page, fields.text, fields.changed, fields.source)
        |> case do
          {:ok, record, position} -> {:ok, document(record), position}
          :done -> :done
        end

      {:error, _reason} ->
        :done
    end
  end

  @doc """
  Explicitly removes one retained case.

  The identity and the lifecycle stay so an operator can see that it was
  deleted; the text is erased, and no summary that quoted it can bring it back.
  """
  @spec delete(String.t()) :: {:ok, CaseRecord.t()} | {:error, term()}
  def delete(case_ref) do
    Repo.transaction(fn ->
      case fetch_and_lock_case(case_ref) do
        {:error, :not_found} -> Repo.rollback(:case_not_found)
        {:ok, record} -> redact!(record)
      end
    end)
  end

  @doc """
  Withdraws every case built from one message a person took back, deleted or
  edited to say something else, inside the transaction that records it.

  Routine expiry of a transcript is not a withdrawal, and a case exists exactly
  so it can outlive one. Taking the words back is different: no derived record
  may keep quoting what the person removed, so the case is redacted rather than
  revalidated into silence later. A case is kept only once its work's history
  is reclaimed, so the message is traced two ways. Work it joined that has no
  case yet keeps a withdrawn one, which capture never rebuilds, so a typo fixed
  while the work runs gives up that work's case. A case already kept is found
  by the message identities it keeps (`source_refs`) and redacted.
  """
  @spec withdraw_message_in_transaction(String.t()) :: :ok
  def withdraw_message_in_transaction(native_input_id) when is_binary(native_input_id) do
    withdraw(
      Episodes.Episode.Query.joined_by_message(native_input_id),
      CaseRecord.Query.citing_message(native_input_id)
    )
  end

  @doc """
  Withdraws every case built from the messages of a conversation that was
  deleted, inside the transaction that removes what Ryker kept of it, as
  `withdraw_message_in_transaction/1` withdraws one message's: work that
  lived there or that one of its messages joined keeps a withdrawn case, and
  a case already kept is found by the conversations it records.
  """
  @spec withdraw_conversation_in_transaction(String.t(), String.t()) :: :ok
  def withdraw_conversation_in_transaction(transport, conversation_ref)
      when is_binary(transport) and is_binary(conversation_ref) do
    withdraw(
      Episodes.Episode.Query.touching_conversation(transport, conversation_ref),
      CaseRecord.Query.from_conversation(transport, conversation_ref)
    )
  end

  # The work first, then the cases kept: a capture committing meanwhile has
  # either not yet reclaimed the history that names the work, or has already
  # written the case the second look finds. Both go in episode order, the
  # order capture keeps cases in, so the two never wait on each other.
  defp withdraw(work, kept) do
    work
    |> Episodes.Episode.Query.ordered_by_id()
    |> Repo.all()
    |> Enum.each(&withdraw_work!/1)

    kept
    |> CaseRecord.Query.active()
    |> CaseRecord.Query.ordered_by_case_ref()
    |> CaseRecord.Query.lock_for_update()
    |> Repo.all()
    |> Enum.each(&redact!/1)
  end

  # Work with no case yet keeps a withdrawn one; one kept meanwhile is
  # redacted instead.
  defp withdraw_work!(%Episodes.Episode{} = episode) do
    now = Repo.now!()

    withdrawn = %{
      id: Repo.generate_id(),
      case_ref: "case:#{episode.id}",
      closed_at: episode.updated_at,
      content_fingerprint: CanonicalJSON.digest(%{"problem" => @redacted}),
      conversation_ref: episode.destination_conversation_ref,
      episode_id: episode.id,
      episode_key: episode.key,
      execution_mode: episode.execution_mode,
      inserted_at: now,
      problem: @redacted,
      search_text: "",
      source_refs: source_refs(episode.id),
      conversation_refs: conversation_refs(episode.id),
      status: :deleted,
      transport: episode.destination_transport,
      updated_at: now,
      workspace_ref: Episodes.Scope.workspace_ref(episode)
    }

    case Repo.insert_all(CaseRecord, [withdrawn],
           on_conflict: :nothing,
           conflict_target: [:case_ref]
         ) do
      {1, _inserted} ->
        announce_case(struct!(CaseRecord, withdrawn))

      {0, _kept} ->
        case fetch_and_lock_case(withdrawn.case_ref) do
          {:ok, %CaseRecord{status: :active} = record} -> redact!(record)
          _withdrawn -> :ok
        end
    end
  end

  defp fetch_and_lock_case(case_ref) do
    case_ref
    |> CaseRecord.Query.by_case_ref()
    |> CaseRecord.Query.lock_for_update()
    |> Repo.fetch()
  end

  # The identity and the lifecycle stay; the text is erased.
  defp redact!(%CaseRecord{} = record) do
    record
    |> Ecto.Changeset.change(
      attempted_actions: [],
      cause: nil,
      links: [],
      outcome: nil,
      problem: @redacted,
      search_text: "",
      status: :deleted,
      anchor_keys: []
    )
    |> Repo.update!()
    |> tap(&announce_case/1)
  end

  # A case is stamped by the database clock, the one a memory search takes its
  # cutoff from; the host clock running ahead of it hid a case captured a
  # moment before from the search that followed.
  #
  # It is read under the lock a forget takes before erasing it. Read unlocked,
  # a forget that committed between the read and the rewrite came partly
  # undone: every word that had changed since was written back into the
  # forgotten case.
  defp persist(%Episodes.Episode{} = episode) do
    attributes = attributes(episode)

    Repo.transaction(fn ->
      now = Repo.now!()

      case fetch_and_lock_case(attributes.case_ref) do
        {:ok, %CaseRecord{content_fingerprint: same} = record}
        when same == :erlang.map_get(:content_fingerprint, attributes) ->
          record

        {:ok, %CaseRecord{status: :deleted} = record} ->
          record

        {:ok, %CaseRecord{} = record} ->
          attributes = Map.put(attributes, :updated_at, now)

          record
          |> Ecto.Changeset.change(attributes)
          |> Repo.update!()
          |> tap(&announce_case/1)

        {:error, :not_found} ->
          attributes = Map.merge(attributes, %{inserted_at: now, updated_at: now})

          CaseRecord
          |> struct!(attributes)
          |> Repo.insert!(on_conflict: :nothing, conflict_target: [:case_ref])
          |> tap(&announce_case/1)
      end
    end)
  end

  # A remembered case shows on the memory pages and on the request it was
  # captured from.
  defp announce_case(%CaseRecord{id: id, episode_id: episode_id}) when is_binary(id) do
    Ryker.Episodes.broadcast_episode_updated(episode_id)
    Ryker.Memories.broadcast_memory_updated(id)
  end

  defp announce_case(_not_written), do: :ok

  defp attributes(%Episodes.Episode{} = episode) do
    digest = Repo.peek(Episodes.RoutingDigest.Query.by_episode_id(episode.id))
    problem = bounded(digest_problem(digest, episode), @problem_bytes)
    checked = Enum.flat_map(records(episode.id, "evidence"), &checked/1)

    content = %{
      attempted_actions: attempted_actions(checked),
      cause: bounded(cause(records(episode.id, "finding")), @cause_bytes),
      occurrence_refs: occurrence_refs(episode.id),
      outcome: bounded(outcome(episode.id), @outcome_bytes),
      problem: problem
    }

    fingerprint =
      content
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
      |> CanonicalJSON.digest()

    Map.merge(content, %{
      anchor_keys: Enum.take(anchor_keys(digest), @maximum_anchors),
      case_ref: "case:#{episode.id}",
      closed_at: episode.updated_at,
      content_fingerprint: fingerprint,
      conversation_ref: episode.destination_conversation_ref,
      episode_id: episode.id,
      episode_key: episode.key,
      execution_mode: episode.execution_mode,
      links: Enum.take(links(episode.id), @maximum_links),
      repository_ref: repository_ref(episode.id),
      search_text: bounded(search_text(content, digest), @search_bytes),
      source_refs: source_refs(episode.id),
      conversation_refs: conversation_refs(episode.id),
      status: :active,
      transport: episode.destination_transport,
      workspace_ref: Episodes.Scope.workspace_ref(episode)
    })
  end

  defp digest_problem(%Episodes.RoutingDigest{objective: objective}, _episode)
       when is_binary(objective) and objective != "",
       do: objective

  defp digest_problem(_digest, %Episodes.Episode{key: key}), do: "Work #{key}"

  defp digest_text(%Episodes.Episode{} = episode) do
    case Repo.fetch(Episodes.RoutingDigest.Query.by_episode_id(episode.id)) do
      {:ok, %Episodes.RoutingDigest{} = digest} ->
        "#{digest.objective} #{digest.latest_development}"

      {:error, :not_found} ->
        ""
    end
  end

  defp anchor_keys(%Episodes.RoutingDigest{anchor_keys: keys}) when is_list(keys), do: keys
  defp anchor_keys(_digest), do: []

  defp search_text(content, digest) do
    [
      content.problem,
      content.cause,
      content.outcome,
      Enum.join(content.attempted_actions, "\n"),
      if(digest, do: digest.search_text)
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join("\n")
  end

  defp outcome(episode_id), do: Repo.peek(Work.Turn.Query.latest_answer_message(episode_id))

  # What the work still stands by: a replaced record, and a finding a person
  # forgot or marked explained (`Ryker.Records.Findings`), are left out.
  defp records(episode_id, kind) do
    episode_id
    |> Records.Record.Query.by_episode_id()
    |> Records.Record.Query.by_kind(kind)
    |> Records.Record.Query.in_use()
    |> Records.Record.Query.ordered_by_oldest()
    |> Records.Record.Query.limit_to(32)
    |> Records.Record.Query.select_payloads()
    |> Repo.all()
  end

  # The cause is what the work found and explained; an unexplained, expected
  # or out-of-scope finding is not one, and none is better than a guess.
  defp cause(findings) do
    Enum.find_value(findings, fn
      %{"status" => "explained", "what" => what} when is_binary(what) and what != "" -> what
      _finding -> nil
    end)
  end

  # What was tried is what the work checked, and where.
  defp checked(%{"observation" => observation, "source_name" => source})
       when is_binary(observation) and observation != "" and is_binary(source) and source != "",
       do: [source <> ": " <> observation]

  defp checked(_evidence), do: []

  # Each bounded, and as many as fit the case's share of a search answer.
  defp attempted_actions(checked) do
    checked
    |> Enum.take(@maximum_actions)
    |> Enum.map(&bounded(&1, @action_bytes))
    |> Enum.reduce_while({[], 2}, fn action, {kept, used} ->
      size = byte_size(CanonicalJSON.encode!(action)) + 1

      if used + size <= @actions_bytes,
        do: {:cont, {[action | kept], used + size}},
        else: {:halt, {kept, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  # The newest claims, as later work recurs on them.
  defp occurrence_refs(episode_id) do
    episode_id
    |> Episodes.CorrelationClaim.Query.by_episode_id()
    |> Episodes.CorrelationClaim.Query.ordered_by_recent()
    |> Episodes.CorrelationClaim.Query.limit_to(@maximum_occurrences)
    |> Episodes.CorrelationClaim.Query.select_occurrence_refs()
    |> Repo.all()
    |> Enum.sort()
  end

  defp links(episode_id) do
    episode_id
    |> Episodes.Origin.Query.by_episode_id()
    |> Episodes.Origin.Query.ordered_by_occurred_at()
    |> Episodes.Origin.Query.select_source_item_refs()
    |> Repo.all()
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Every conversation the work's messages came from, so that deleting any of
  # them finds the case (`withdraw_conversation_in_transaction/2`).
  defp conversation_refs(episode_id),
    do: episode_id |> Episodes.Origin.Query.conversation_refs() |> Repo.all() |> Enum.take(64)

  # Lineage is kept by the source identity the adapter issued, not by this
  # episode's event key, so an explicit withdrawal of that exact message can
  # still find every record derived from it after the transcript is gone.
  defp source_refs(episode_id) do
    episode_id
    |> Episodes.Origin.Query.by_episode_id()
    |> Episodes.Origin.Query.ordered_by_occurred_at()
    |> Episodes.Origin.Query.select_native_input_ids()
    |> Repo.all()
    |> Enum.uniq()
    |> Enum.take(64)
  end

  defp repository_ref(episode_id),
    do: Repo.peek(Work.Turn.Query.latest_repository_ref(episode_id))

  defp document(%CaseRecord{} = record) do
    %{
      "attempted_actions" => record.attempted_actions,
      "case_ref" => record.case_ref,
      "cause" => record.cause,
      "closed_at" => DateTime.to_iso8601(record.closed_at),
      "conversation_ref" => record.conversation_ref,
      "kind" => "case",
      "links" => record.links,
      "occurrence_refs" => record.occurrence_refs,
      "outcome" => record.outcome,
      "problem" => record.problem,
      "repository_ref" => record.repository_ref
    }
  end

  defp bounded(nil, _limit), do: nil
  defp bounded(text, limit), do: String.byte_slice(text, 0, limit)
end
