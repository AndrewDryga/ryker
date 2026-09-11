defmodule Responder.State.Cases do
  @moduledoc """
  Durable custody for completed cases and the lessons drawn from them.

  Everything Responder learned from an incident used to expire with the raw
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

  alias Responder.CanonicalJSON
  alias Responder.Episodes.{CorrelationClaim, Episode, Origin, RoutingDigest, RoutingDigests}
  alias Responder.Repo
  alias Responder.State.{CaseLesson, CaseRecord, MemorySearchPage, Record}
  alias Responder.Work.Turn

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
  cleanup, so a pending lesson review is never the reason the useful part of
  an incident disappears at the history horizon.
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
              "to_tsvector('simple', ?) @@ to_tsquery('simple', ?)",
              record.search_text,
              ^terms
            ),
          order_by: [
            desc:
              fragment(
                "ts_rank_cd(to_tsvector('simple', ?), to_tsquery('simple', ?))",
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

  @doc "One `search_memory` page over retained cases and their approved lessons."
  @spec search_page(map(), map()) :: {:ok, map(), list()} | :done
  def search_page(context, page) do
    from(record in CaseRecord,
      where:
        record.status == :active and record.workspace_ref == ^context.workspace_ref and
          ^scope_filter(context, page.scope)
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
  Records one extracted lesson as a draft.

  A draft is never presented as approved guidance; only review makes it so.
  """
  @spec draft_lesson(map()) :: {:ok, CaseLesson.t()} | {:error, term()}
  def draft_lesson(%{case_ref: case_ref} = attributes) do
    case Repo.get_by(CaseRecord, case_ref: case_ref, status: :active) do
      nil ->
        {:error, :case_not_found}

      %CaseRecord{} = record ->
        Repo.insert(
          %CaseLesson{
            anchor_keys: record.anchor_keys,
            case_id: record.id,
            conditions: attributes.conditions,
            lesson_ref: "lesson:#{case_ref}:#{attributes.revision}",
            risks: Map.get(attributes, :risks),
            search_text:
              bounded(
                Enum.join([attributes.conditions, attributes.steps, record.problem], "\n"),
                @search_bytes
              ),
            source_refs: record.source_refs,
            status: :draft,
            steps: attributes.steps,
            verification: Map.get(attributes, :verification),
            workspace_ref: record.workspace_ref
          },
          on_conflict: :nothing,
          conflict_target: [:lesson_ref]
        )
        |> case do
          {:ok, %CaseLesson{id: nil}} ->
            {:ok,
             Repo.get_by!(CaseLesson, lesson_ref: "lesson:#{case_ref}:#{attributes.revision}")}

          {:ok, lesson} ->
            {:ok, lesson}

          {:error, changeset} ->
            {:error, {:invalid_case_lesson, changeset.errors}}
        end
    end
  end

  @doc "Marks one reviewed lesson approved and supersedes the revision it replaces."
  @spec approve_lesson(String.t(), String.t(), String.t()) ::
          {:ok, CaseLesson.t()} | {:error, term()}
  def approve_lesson(lesson_ref, actor_ref, review_ref) do
    Repo.transaction(fn ->
      case Repo.one(
             from(lesson in CaseLesson,
               where: lesson.lesson_ref == ^lesson_ref and lesson.status == :draft,
               lock: "FOR UPDATE"
             )
           ) do
        nil ->
          Repo.rollback(:case_lesson_not_reviewable)

        lesson ->
          superseded = supersede_previous(lesson)

          lesson
          |> Ecto.Changeset.change(
            reviewed_at: DateTime.utc_now(),
            reviewed_by_actor_ref: actor_ref,
            review_ref: review_ref,
            status: :approved,
            supersedes_lesson_id: superseded
          )
          |> Repo.update!()
      end
    end)
  end

  @doc """
  Explicitly removes one retained case and everything derived from it.

  The identity and the lifecycle stay so an operator can see that it was
  deleted; the text is erased, and no summary that quoted it can bring it back.
  """
  @spec delete(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete(case_ref) do
    Repo.transaction(fn ->
      case Repo.one(
             from(record in CaseRecord, where: record.case_ref == ^case_ref, lock: "FOR UPDATE")
           ) do
        nil ->
          Repo.rollback(:case_not_found)

        record ->
          {lessons, _} =
            Repo.update_all(
              from(lesson in CaseLesson,
                where: lesson.case_id == ^record.id and lesson.status != :removed
              ),
              set: [
                conditions: "(removed)",
                search_text: "",
                status: :removed,
                steps: "(removed)",
                verification: nil,
                risks: nil,
                updated_at: DateTime.utc_now()
              ]
            )

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

          lessons + 1
      end
    end)
  end

  @doc """
  Redacts every retained case built from one explicitly withdrawn source.

  Routine expiry of a transcript is not a withdrawal, and a case exists exactly
  so it can outlive one. Somebody deleting the message is different: no derived
  record may keep quoting what they removed, so the case and its lessons are
  redacted rather than revalidated into silence later.
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
        {:ok, _count} -> redacted + 1
        {:error, _reason} -> redacted
      end
    end)
  end

  @doc "The approved, reusable lessons of one retained case."
  @spec approved_lessons(Ecto.UUID.t()) :: [CaseLesson.t()]
  def approved_lessons(case_id) do
    Repo.all(
      from(lesson in CaseLesson,
        where: lesson.case_id == ^case_id and lesson.status == :approved,
        order_by: [desc: lesson.reviewed_at]
      )
    )
  end

  defp persist(%Episode{} = episode) do
    attributes = attributes(episode)
    now = DateTime.utc_now()

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

      nil ->
        Repo.insert(struct!(CaseRecord, attributes),
          on_conflict: :nothing,
          conflict_target: [:case_ref]
        )
    end
  end

  defp attributes(%Episode{} = episode) do
    digest = Repo.get_by(RoutingDigest, episode_id: episode.id)
    problem = bounded(digest_problem(digest, episode), @problem_bytes)
    findings = records(episode.id, "finding")
    actions = records(episode.id, "action") ++ records(episode.id, "evidence")

    content = %{
      attempted_actions: Enum.take(actions, @maximum_actions),
      cause: bounded(List.first(findings), @cause_bytes),
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

  defp records(episode_id, kind) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and record.kind == ^kind and
            record.status != :superseded,
        order_by: [asc: record.inserted_at],
        limit: 32,
        select: fragment("?::jsonb ->> 'summary'", record.payload)
      )
    )
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
  end

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
      "lessons" => Enum.map(approved_lessons(record.id), &lesson_document/1),
      "links" => record.links,
      "occurrence_refs" => record.occurrence_refs,
      "outcome" => record.outcome,
      "problem" => record.problem,
      "repository_ref" => record.repository_ref
    }
  end

  defp lesson_document(%CaseLesson{} = lesson) do
    %{
      "conditions" => lesson.conditions,
      "lesson_ref" => lesson.lesson_ref,
      "reviewed_at" => DateTime.to_iso8601(lesson.reviewed_at),
      "risks" => lesson.risks,
      "steps" => lesson.steps,
      "verification" => lesson.verification
    }
  end

  defp supersede_previous(%CaseLesson{} = lesson) do
    case Repo.one(
           from(previous in CaseLesson,
             where:
               previous.case_id == ^lesson.case_id and previous.status == :approved and
                 previous.id != ^lesson.id,
             order_by: [desc: previous.reviewed_at],
             limit: 1,
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        nil

      previous ->
        previous |> Ecto.Changeset.change(status: :superseded) |> Repo.update!()
        previous.id
    end
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
