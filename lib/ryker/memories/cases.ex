defmodule Ryker.Memories.Cases do
  @moduledoc """
  Durable custody for completed cases.

  Everything Ryker learned from an incident used to expire with the raw
  transcript that produced it, so a matching outage a year later started from
  nothing. A case is captured from the episode's own retained evidence before
  that evidence is eligible for cleanup, keeps no raw payload, and is bounded
  by its own explicit lifetime rather than the transcript's.

  Capture is idempotent by content: repeated close, reopen, cleanup and
  restart events update one case per intended revision instead of appending a
  new one, so nothing here can become a loop that feeds on its own output.
  Deletion is explicit and redacts the text while keeping the identity, so a
  deleted case cannot be reconstructed from a summary that quoted it.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.{CorrelationClaim, Episode, Origin, RoutingDigest, RoutingDigests}
  alias Ryker.Memories.CaseRecord
  alias Ryker.Memories.MemorySearchPage
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Work.Turn

  @problem_bytes 4_096
  @cause_bytes 4_096
  @outcome_bytes 4_096
  @search_bytes 16_384
  @maximum_actions 32
  @maximum_links 32
  @maximum_anchors 64
  @terminal_states [:complete, :cancelled]
  @recall_limit 5

  @doc """
  Captures or refreshes the compact case for each finished episode.

  Retention calls this before the raw episode rows become eligible for
  cleanup, so the useful part of an incident never disappears at the history
  horizon.
  """
  @spec capture_many([Ecto.UUID.t()]) :: non_neg_integer()
  def capture_many([]), do: 0

  def capture_many(episode_ids) do
    episode_ids
    |> Enum.map(&capture/1)
    |> Enum.count(&match?({:ok, _case}, &1))
  end

  @doc "Captures one finished episode; unfinished work has no case yet."
  @spec capture(Ecto.UUID.t()) :: {:ok, CaseRecord.t()} | {:error, term()}
  def capture(episode_id) do
    case Repo.get(Episode, episode_id) do
      %Episode{state: state} = episode when state in @terminal_states -> persist(episode)
      %Episode{} -> {:error, :case_episode_active}
      nil -> {:error, :case_episode_not_found}
    end
  end

  @doc """
  Related retained cases for one episode, newest evidence first.

  This is recall, never authority: a historical fix is advice about what
  worked once, not proof that this incident has the same cause.
  """
  @spec recall(Episode.t(), pos_integer()) :: [map()]
  def recall(%Episode{} = episode, limit \\ @recall_limit) do
    terms = RoutingDigests.search_terms(digest_text(episode))

    if terms == "" do
      []
    else
      Repo.all(
        from(record in CaseRecord,
          where:
            record.status == :active and record.workspace_ref == ^workspace_ref(episode) and
              record.execution_mode == ^episode.execution_mode and
              record.episode_id != ^episode.id,
          where:
            fragment(
              "to_tsvector('english', ?) @@ to_tsquery('english', ?)",
              record.search_text,
              ^terms
            ),
          order_by: [
            desc:
              fragment(
                "ts_rank_cd(to_tsvector('english', ?), to_tsquery('english', ?), 32)",
                record.search_text,
                ^terms
              ),
            desc: record.closed_at
          ],
          limit: ^limit
        )
      )
      |> Enum.map(&document/1)
    end
  end

  @doc "One `search_memory` page over retained cases."
  @spec search_page(map(), map()) :: {:ok, map(), list()} | :done
  def search_page(context, page) do
    # A dynamic filter must be its own `where`: inside the boolean above it,
    # Ecto refused the query and every memory search failed.
    from(record in CaseRecord,
      where: record.status == :active and record.workspace_ref == ^context.workspace_ref,
      where: ^scope_filter(context, page.scope)
    )
    |> MemorySearchPage.one(
      page,
      dynamic([record], record.search_text),
      dynamic([record], record.updated_at),
      dynamic([record], record.closed_at)
    )
    |> case do
      {:ok, record, position} -> {:ok, document(record), position}
      :done -> :done
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
      case Repo.one(
             from(record in CaseRecord, where: record.case_ref == ^case_ref, lock: "FOR UPDATE")
           ) do
        nil ->
          Repo.rollback(:case_not_found)

        record ->
          record
          |> Ecto.Changeset.change(
            attempted_actions: [],
            cause: nil,
            links: [],
            outcome: nil,
            problem: "(deleted)",
            search_text: "",
            status: :deleted,
            anchor_keys: []
          )
          |> Repo.update!()
          |> tap(&announce_case/1)
      end
    end)
  end

  @doc """
  Redacts every retained case built from one explicitly withdrawn source.

  Routine expiry of a transcript is not a withdrawal, and a case exists exactly
  so it can outlive one. Somebody deleting the message is different: no derived
  record may keep quoting what they removed, so the case is redacted rather
  than revalidated into silence later.
  """
  @spec withdraw_source(String.t()) :: non_neg_integer()
  def withdraw_source(native_input_id) when is_binary(native_input_id) do
    Repo.all(
      from(record in CaseRecord,
        where: record.status == :active and ^native_input_id in record.source_refs,
        select: record.case_ref
      )
    )
    |> Enum.reduce(0, fn case_ref, redacted ->
      case delete(case_ref) do
        {:ok, _record} -> redacted + 1
        {:error, _reason} -> redacted
      end
    end)
  end

  # A case is stamped by the database clock, the one a memory search takes its
  # cutoff from; the host clock running ahead of it hid a case captured a
  # moment before from the search that followed.
  defp persist(%Episode{} = episode) do
    attributes = attributes(episode)
    now = Repo.now!()

    case Repo.get_by(CaseRecord, case_ref: attributes.case_ref) do
      %CaseRecord{content_fingerprint: same} = record
      when same == :erlang.map_get(:content_fingerprint, attributes) ->
        {:ok, record}

      %CaseRecord{status: :deleted} = record ->
        {:ok, record}

      %CaseRecord{} = record ->
        record
        |> Ecto.Changeset.change(Map.put(attributes, :updated_at, now))
        |> Repo.update()
        |> tap(&announce_case/1)

      nil ->
        struct!(CaseRecord, Map.merge(attributes, %{inserted_at: now, updated_at: now}))
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:case_ref])
        |> tap(&announce_case/1)
    end
  end

  # A remembered case shows on the memory pages and on the request it was
  # captured from.
  defp announce_case({:ok, %CaseRecord{id: id} = record}) when is_binary(id),
    do: announce_case(record)

  defp announce_case(%CaseRecord{id: id, episode_id: episode_id}) when is_binary(id) do
    Ryker.Episodes.broadcast_episode_updated(episode_id)
    Ryker.Memories.broadcast_memory_updated(id)
  end

  defp announce_case(_not_written), do: :ok

  defp attributes(%Episode{} = episode) do
    digest = Repo.get_by(RoutingDigest, episode_id: episode.id)
    problem = bounded(digest_problem(digest, episode), @problem_bytes)
    checked = Enum.flat_map(records(episode.id, "evidence"), &checked/1)

    content = %{
      attempted_actions: Enum.take(checked, @maximum_actions),
      cause: bounded(cause(records(episode.id, "finding")), @cause_bytes),
      occurrence_refs: occurrence_refs(episode.id),
      outcome: bounded(outcome(episode.id), @outcome_bytes),
      problem: problem
    }

    Map.merge(content, %{
      anchor_keys: Enum.take(anchor_keys(digest), @maximum_anchors),
      case_ref: "case:#{episode.id}",
      closed_at: episode.updated_at,
      content_fingerprint:
        content
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> CanonicalJSON.digest(),
      conversation_ref: episode.destination_conversation_ref,
      episode_id: episode.id,
      episode_key: episode.key,
      execution_mode: episode.execution_mode,
      links: Enum.take(links(episode.id), @maximum_links),
      repository_ref: repository_ref(episode.id),
      search_text: bounded(search_text(content, digest), @search_bytes),
      source_refs: source_refs(episode.id),
      status: :active,
      transport: episode.destination_transport,
      workspace_ref: workspace_ref(episode)
    })
  end

  defp digest_problem(%RoutingDigest{objective: objective}, _episode)
       when is_binary(objective) and objective != "",
       do: objective

  defp digest_problem(_digest, %Episode{key: key}), do: "Work #{key}"

  defp digest_text(%Episode{} = episode) do
    case Repo.get_by(RoutingDigest, episode_id: episode.id) do
      %RoutingDigest{} = digest -> "#{digest.objective} #{digest.latest_development}"
      nil -> ""
    end
  end

  defp anchor_keys(%RoutingDigest{anchor_keys: keys}) when is_list(keys), do: keys
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

  defp outcome(episode_id) do
    Repo.one(
      from(turn in Turn,
        where:
          turn.episode_id == ^episode_id and turn.status in [:settled, :delivery_pending] and
            not is_nil(turn.result_ref),
        order_by: [desc: turn.accepted_at, desc: turn.inserted_at],
        limit: 1,
        select: fragment("?::jsonb ->> 'message'", turn.delivery_document)
      )
    )
  end

  # What the work still stands by: a replaced record, and a finding a person
  # forgot or marked explained (`Ryker.Records.Findings`), are left out.
  defp records(episode_id, kind) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and record.kind == ^kind and
            record.status in [:open, :confirmed],
        order_by: [asc: record.inserted_at],
        limit: 32,
        select: record.payload
      )
    )
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

  defp occurrence_refs(episode_id) do
    Repo.all(
      from(claim in CorrelationClaim,
        where: claim.episode_id == ^episode_id,
        order_by: [asc: claim.occurrence_ref],
        select: claim.occurrence_ref
      )
    )
  end

  defp links(episode_id) do
    Repo.all(
      from(origin in Origin,
        where: origin.episode_id == ^episode_id and origin.effective,
        order_by: [asc: origin.occurred_at],
        select: origin.source_item_ref
      )
    )
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Lineage is kept by the source identity the adapter issued, not by this
  # episode's event key, so an explicit withdrawal of that exact message can
  # still find every record derived from it after the transcript is gone.
  defp source_refs(episode_id) do
    Repo.all(
      from(origin in Origin,
        where: origin.episode_id == ^episode_id and origin.effective,
        order_by: [asc: origin.occurred_at],
        select: origin.native_input_id
      )
    )
    |> Enum.uniq()
    |> Enum.take(64)
  end

  defp repository_ref(episode_id) do
    Repo.one(
      from(turn in Turn,
        join: session in assoc(turn, :session),
        where: turn.episode_id == ^episode_id and not is_nil(session.repository_ref),
        order_by: [desc: turn.inserted_at],
        limit: 1,
        select: session.repository_ref
      )
    )
  end

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

  defp scope_filter(context, "current_channel"),
    do: dynamic([record], record.conversation_ref == ^context.conversation_ref)

  defp scope_filter(%{repository: repository}, "repository") when is_binary(repository),
    do: dynamic([record], record.repository_ref == ^repository)

  defp scope_filter(_context, scope) when scope in ["workspace", "global"],
    do: dynamic([_record], true)

  defp scope_filter(_context, _scope), do: dynamic([_record], false)

  defp workspace_ref(%Episode{} = episode) do
    case String.split(episode.destination_conversation_ref, ":", parts: 3) do
      [transport, id, _rest] -> "#{transport}:#{id}"
      _other -> episode.destination_conversation_ref
    end
  end

  defp bounded(nil, _limit), do: nil
  defp bounded(text, limit), do: String.byte_slice(text, 0, limit)
end
