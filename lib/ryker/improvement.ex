defmodule Ryker.Improvement do
  @moduledoc """
  Requests people were unhappy with, each diagnosed by Ryker itself and turned
  into an eval case when a person accepts it.

  Andrew, 2026-09-27: "use that sentiment as indirect feedback channel ... do
  something about it (at very least see where users were frustrated to see
  what happened and fix the issue). Ideally, we need evals building based on
  sentiment and self-analysis without much of manual human reviews."

  **Candidates.** A request (an episode, or a message routing answered by
  itself) becomes one candidate the moment it gets its first negative
  feedback (`Ryker.Feedback`), in the same transaction, and every later
  negative signal only adds to it. Negative is exactly one of:

  - routing read the person's next message as frustrated or angry;
  - a reaction that judges the answer (`negative_reactions/0`);
  - the same person asked the same thing again soon after the answer;
  - the person edited or deleted their message after the answer;
  - a person rated how the request went as needing work.

  Positive and neutral feedback never creates one; it is still evidence for
  the analysis of a request that has one.

  **Self-analysis.** Once the request has come to rest and no new negative
  feedback has arrived for a quiet time, a background worker asks the
  learning models once what went wrong (`Ryker.Improvement.Analyses`,
  `Ryker.Improvement.Prompt`): whose fault (host bug, prompt bug, model
  mistake, not a problem, unclear), at which step (routing, Work, delivery),
  what went wrong, what Ryker should have done as an eval expectation, and
  how sure it is. It runs while background learning is on.

  **Decisions.** A person accepts a candidate as an eval case, which freezes
  the evidence it rests on (`Ryker.Improvement.Evidence`) so the case outlives
  the request's messages, or dismisses it; either keeps the record, and
  either can be changed later. Accepted cases export as world scenarios
  (`Ryker.Improvement.Export`).

  Every change is announced after the outermost commit
  (`subscribe_improvement/0`). A candidate names its request without a
  foreign key, like a routing example: it expires on its own window
  (`Ryker.Retention.Data`), and a person forgetting, deleting or editing a
  message, or forgetting a topic or a channel it quotes, erases what it holds
  (`forget_in_transaction/1`).
  """

  alias Ryker.Episodes.EpisodeQuery
  alias Ryker.Feedback.Signal
  alias Ryker.Improvement.{AnalysisRunQuery, Candidate, CandidateQuery, Evidence}
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.EntryQuery
  alias Ryker.Repo
  alias Ryker.RoutingExamples

  # "stopped" named a review of a cancelled request, before ratings; it stays
  # so the candidates it made still read.
  @reasons ~w(frustrated reaction asked_again edited rated stopped)

  # Reactions that judge the answer itself. The Feedback page counts a longer
  # list as frustrated, but crying, worried or weary faces are as often about
  # the news an answer carried (an outage, a failed deploy) as about the
  # answer; only these say the answer was wrong or unhelpful.
  @negative_reactions ~w(
    -1 thumbsdown x confused face_with_rolling_eyes unamused disappointed rage angry
    facepalm face_palm man-facepalming woman-facepalming person_facepalming
  )

  @doc "The kinds of negative feedback a candidate records, in the order the page names them."
  @spec reasons() :: [String.t()]
  def reasons, do: @reasons

  @doc "The reactions that make a request a candidate: 👎 and the few like it."
  @spec negative_reactions() :: [String.t()]
  def negative_reactions, do: @negative_reactions

  @doc """
  The kind of negative feedback `signal` is, or nil when it is not negative:
  `frustrated`, `reaction`, `asked_again`, `edited` or `rated`.
  """
  @spec reason(Signal.t() | map()) :: String.t() | nil
  def reason(%{kind: :sentiment, value: feeling}) when feeling in ["frustrated", "angry"],
    do: "frustrated"

  def reason(%{kind: :reaction_added, value: emoji}) when emoji in @negative_reactions,
    do: "reaction"

  def reason(%{kind: :asked_again}), do: "asked_again"
  def reason(%{kind: kind}) when kind in [:message_edited, :message_deleted], do: "edited"
  def reason(%{kind: :reviewed, value: "needs_work"}), do: "rated"
  def reason(_signal), do: nil

  # -- Candidates ---------------------------------------------------------------------

  @doc """
  Makes the request `signal` is about a candidate when the signal is
  negative, inside the transaction that records the signal
  (`Ryker.Feedback.record_in_transaction/1`), which already holds the
  request. The first negative signal creates it; each later one adds its
  kind, counts it and moves `last_signal_at`, so a burst of feedback is
  analyzed once, after it. Anything else changes nothing.
  """
  @spec note_in_transaction(Signal.t()) :: :ok
  def note_in_transaction(%Signal{} = signal) do
    case reason(signal) do
      nil -> :ok
      reason -> signal |> request_row(reason) |> upsert()
    end
  end

  defp request_row(%Signal{episode_id: id} = signal, reason) when is_binary(id) do
    episode = id |> EpisodeQuery.by_id() |> EpisodeQuery.select_request_fields() |> Repo.one!()

    row(signal, reason, %{
      episode_id: id,
      input_id: nil,
      request_ref: episode.key,
      transport: episode.destination_transport,
      conversation_ref: episode.destination_conversation_ref
    })
  end

  defp request_row(%Signal{input_id: id} = signal, reason) when is_binary(id) do
    entry = id |> EntryQuery.by_id() |> EntryQuery.select_destinations() |> Repo.one!()

    row(signal, reason, %{
      episode_id: nil,
      input_id: id,
      request_ref: Inbox.ref(entry),
      transport: entry.destination_transport,
      conversation_ref: entry.destination_conversation_ref
    })
  end

  defp row(signal, reason, request) do
    now = Repo.now!()

    Map.merge(request, %{
      id: Ecto.UUID.generate(),
      reasons: [reason],
      signal_count: 1,
      first_signal_at: signal.occurred_at,
      last_signal_at: signal.occurred_at,
      inserted_at: now,
      updated_at: now
    })
  end

  defp upsert(row) do
    target = if row.episode_id, do: :episode_id, else: :input_id

    {1, [%{id: id}]} =
      Repo.insert_all(Candidate, [row],
        on_conflict: CandidateQuery.merge_signal(),
        conflict_target: [target],
        returning: [:id]
      )

    broadcast_improvement_updated(id)
  end

  @doc "The candidate about a request, or nil."
  @spec for_request(Ryker.Feedback.request()) :: Candidate.t() | nil
  def for_request({:episode, id}) when is_binary(id),
    do: Repo.one(CandidateQuery.by_episode_id(id))

  def for_request({:input, id}) when is_binary(id), do: Repo.one(CandidateQuery.by_input_id(id))
  def for_request(_request), do: nil

  @doc """
  What `from` up to `to` brought, among the candidates nobody forgot: how many
  were `found` (created then), by what Ryker made of them (`categories`, in
  the order the page lists them, only those with any; `waiting` still to
  analyze; `not_analyzed` the rest), and how many were `accepted` or
  `dismissed` then. What to fix says it for the last seven days.
  """
  @spec week(DateTime.t(), DateTime.t()) :: map()
  def week(%DateTime{} = from, %DateTime{} = to) do
    found = CandidateQuery.kept() |> CandidateQuery.created_between(from, to)
    decided = CandidateQuery.kept() |> CandidateQuery.decided_between(from, to)
    categories = found |> CandidateQuery.count_by_category() |> Repo.all() |> Map.new()

    counts = %{
      found: Repo.aggregate(found, :count),
      waiting: found |> CandidateQuery.awaiting_analysis() |> Repo.aggregate(:count),
      accepted: decided |> CandidateQuery.with_status(:accepted) |> Repo.aggregate(:count),
      dismissed: decided |> CandidateQuery.with_status(:dismissed) |> Repo.aggregate(:count)
    }

    Map.merge(counts, %{
      categories:
        for(
          category <- Candidate.categories(),
          Map.has_key?(categories, category),
          do: {category, Map.fetch!(categories, category)}
        ),
      not_analyzed: counts.found - (categories |> Map.values() |> Enum.sum()) - counts.waiting
    })
  end

  # -- Words -----------------------------------------------------------------------

  @doc "A category's name: Host bug, Prompt bug, …"
  @spec category_label(atom()) :: String.t()
  def category_label(:host_bug), do: "Host bug"
  def category_label(:prompt_bug), do: "Prompt bug"
  def category_label(:model_mistake), do: "Model mistake"
  def category_label(:not_a_problem), do: "Not a problem"
  def category_label(:unclear), do: "Unclear"

  @doc "A category's name for a count of them: 2 prompt bugs, 1 host bug, 3 unclear."
  @spec category_plural(atom(), non_neg_integer()) :: String.t()
  def category_plural(category, 1), do: category_label(category)
  def category_plural(:not_a_problem, _count), do: "Not a problem"
  def category_plural(:unclear, _count), do: "Unclear"
  def category_plural(category, _count), do: category_label(category) <> "s"

  @doc """
  What a week brought (`week/2`), in words: what was found and what Ryker
  made of it, then what people decided. A quiet week says so rather than
  leaving the line out, which would read as a good week. What to fix's Last
  7 days line reads it.
  """
  @spec week_words(map()) :: String.t()
  def week_words(%{found: 0, accepted: 0, dismissed: 0}),
    do: "Nothing new, and nothing accepted or dismissed."

  def week_words(week), do: found(week) <> " " <> decided(week)

  defp found(%{found: 0}), do: "Nothing new."

  defp found(week) do
    kinds =
      Enum.map(week.categories, fn {category, count} ->
        "#{count} #{String.downcase(category_plural(category, count))}"
      end) ++
        Enum.reject(
          [
            week.waiting > 0 && "#{week.waiting} still to analyze",
            week.not_analyzed > 0 && "#{week.not_analyzed} not analyzed"
          ],
          &(&1 == false)
        )

    "#{week.found} new: #{listed(kinds)}."
  end

  defp decided(%{accepted: 0, dismissed: 0}), do: "None accepted or dismissed."

  defp decided(week) do
    [
      week.accepted == 1 && "1 accepted as an eval case",
      week.accepted > 1 && "#{week.accepted} accepted as eval cases",
      week.dismissed > 0 && "#{week.dismissed} dismissed"
    ]
    |> Enum.reject(&(&1 == false))
    |> listed()
    |> Kernel.<>(".")
  end

  defp listed([only]), do: only
  defp listed(parts), do: Enum.join(Enum.drop(parts, -1), ", ") <> " and " <> List.last(parts)

  # -- Decisions -------------------------------------------------------------------

  @doc """
  Accepts a candidate as an eval case, by `actor_ref`. The evidence it rests
  on is read now and kept with it, so the case can be exported after the
  request's own messages expire. With none of the person's words left there
  is no case, and the error says why (`Ryker.Improvement.Evidence.gather/2`);
  a GitHub request is not kept either, since a world scenario replays Slack
  and Chat messages only (`{:error, :improvement_case_unsupported}`). A
  candidate that was dismissed can still be accepted; one already accepted
  stays as it is.
  """
  @spec accept(term(), String.t()) :: {:ok, Candidate.t()} | {:error, term()}
  def accept(id, actor_ref), do: decide(id, actor_ref, :accepted)

  @doc """
  Whether a candidate's request can become an eval case: a world scenario
  replays Slack and Chat messages, not GitHub comments.
  """
  @spec replayable?(Candidate.t() | map()) :: boolean()
  def replayable?(%{transport: transport}), do: transport in ~w(slack control_plane)

  @doc """
  Dismisses a candidate, by `actor_ref`: it stays on record, listed as
  dismissed, and an analysis still waiting for it is not started. An accepted
  case that is dismissed gives up the evidence it kept.
  """
  @spec dismiss(term(), String.t()) :: {:ok, Candidate.t()} | {:error, term()}
  def dismiss(id, actor_ref), do: decide(id, actor_ref, :dismissed)

  defp decide(id, actor_ref, status) do
    with {:ok, id} <- cast_id(id),
         :ok <- actor(actor_ref) do
      Repo.transaction(fn ->
        :ok = hold_forgetting(status)
        decide_locked(id, actor_ref, status)
      end)
    end
  end

  # Accepting freezes evidence, so it holds forgetting off from before it
  # locks the candidate, as an analysis prompt does
  # (`Ryker.Improvement.Analyses.prepare/2`).
  defp hold_forgetting(:accepted), do: RoutingExamples.copy_lock_in_transaction()
  defp hold_forgetting(_status), do: :ok

  defp decide_locked(id, actor_ref, status) do
    candidate =
      id |> CandidateQuery.by_id() |> CandidateQuery.lock_for_update() |> Repo.one() ||
        Repo.rollback(:improvement_candidate_not_found)

    cond do
      not is_nil(candidate.forgotten_at) -> Repo.rollback(:improvement_candidate_forgotten)
      candidate.status == status -> candidate
      true -> save_decision(candidate, actor_ref, status)
    end
  end

  # A case needs the person's words, from a place a world scenario can
  # replay: without them there is nothing to replay, and accepting one says
  # what is missing instead of keeping a case the download would leave out
  # or the world runner would refuse.
  defp save_decision(candidate, actor_ref, :accepted) do
    unless replayable?(candidate), do: Repo.rollback(:improvement_case_unsupported)
    evidence = Evidence.case_snapshot(candidate)
    if is_nil(evidence.snapshot), do: Repo.rollback(evidence.missing)

    candidate
    |> Ecto.Changeset.change(
      status: :accepted,
      decided_at: Repo.now!(),
      decided_by: actor_ref,
      case_evidence: evidence.snapshot,
      message_keys: Enum.sort(Enum.uniq(candidate.message_keys ++ evidence.message_keys)),
      conversation_refs:
        Enum.sort(Enum.uniq(candidate.conversation_refs ++ evidence.conversation_refs))
    )
    |> Repo.update!()
    |> tap(&broadcast_improvement_updated(&1.id))
  end

  defp save_decision(candidate, actor_ref, :dismissed) do
    candidate
    |> Ecto.Changeset.change(
      status: :dismissed,
      decided_at: Repo.now!(),
      decided_by: actor_ref,
      case_evidence: nil
    )
    |> Repo.update!()
    |> tap(&broadcast_improvement_updated(&1.id))
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :improvement_candidate_not_found}
    end
  end

  defp actor(actor_ref) do
    if Ryker.Reference.valid?(actor_ref, 1_024),
      do: :ok,
      else: {:error, {:invalid_improvement_decision, :actor_ref}}
  end

  # -- Forgetting ---------------------------------------------------------------------

  @doc """
  Erases what candidates hold about the messages and topics a person just
  forgot, deleted or edited, inside the transaction that forgets them
  (`Ryker.RoutingExamples`, which is called from every place that forgets):
  `keys` are the message and topic keys routing examples quote them by. The
  diagnosis, the evidence of an accepted case and the prompts and answers of
  every analysis go; the candidate stays as forgotten, so the same request
  never becomes one again.
  """
  @spec forget_in_transaction([String.t()]) :: :ok
  def forget_in_transaction([]), do: :ok

  def forget_in_transaction(keys) when is_list(keys) do
    keys |> CandidateQuery.quoting_messages() |> erase()
  end

  @doc "Erases what candidates hold about a conversation that was deleted, in its transaction."
  @spec forget_conversation_in_transaction(String.t()) :: :ok
  def forget_conversation_in_transaction(conversation_ref) when is_binary(conversation_ref) do
    conversation_ref |> CandidateQuery.in_conversation() |> erase()
  end

  defp erase(query) do
    now = Repo.now!()

    {_count, ids} =
      Repo.update_all(
        query |> CandidateQuery.kept() |> CandidateQuery.select_ids(),
        set: [
          forgotten_at: now,
          case_evidence: nil,
          what_went_wrong: nil,
          expected: nil,
          updated_at: now
        ]
      )

    if ids != [] do
      Repo.update_all(
        AnalysisRunQuery.kept_for_candidates(ids),
        set: [prompt: nil, result: nil, pruned_at: now, updated_at: now]
      )

      Enum.each(ids, &broadcast_improvement_updated/1)
    end

    :ok
  end

  # -- PubSub ------------------------------------------------------------------------

  @doc """
  Subscribes the caller to candidates: `{:improvement_updated, id}` once a
  candidate is created, gets more feedback, is analyzed or decided, and that
  has committed. The analysis worker wakes on it; the pages redraw on it.
  """
  def subscribe_improvement, do: Ryker.PubSub.subscribe(topic())

  def unsubscribe_improvement, do: Ryker.PubSub.unsubscribe(topic())

  @doc false
  @spec broadcast_improvement_updated(Ecto.UUID.t()) :: :ok
  def broadcast_improvement_updated(id) do
    Repo.after_commit(fn -> Ryker.PubSub.broadcast(topic(), {:improvement_updated, id}) end)
    :ok
  end

  defp topic, do: "improvement"
end
