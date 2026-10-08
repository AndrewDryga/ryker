defmodule Ryker.Feedback.Messages do
  @moduledoc """
  What a person's next message says about Ryker's answer, read as the
  message is received (`Ryker.Ingress.Inbox`), before any model reads it.
  Only people writing in Slack or Chat count; an app, a bot or a webhook
  gives no feedback.

  **Edited or deleted after the answer.** The person edits or deletes a
  message of theirs after Ryker answered it: after the message was first
  sent, Ryker delivered an answer to the request it belongs to (a Work reply
  of its episode, or the quick reply routing sent for it), and the edit or
  deletion came after that answer. Fixing a typo before Ryker answered is
  not feedback.

  **Asked again.** The same person asks the same thing again soon after the
  answer, and both are plainly defined, conservatively:

  - soon: the new message is sent within ten minutes after Ryker delivered
    its answer to the earlier message;
  - again: the new message repeats the earlier one. Once case, punctuation,
    mentions and links are set aside, the two read the same; or, leaving out
    small words such as "the", "is", "please" or "still", they use the same
    words; or, for longer questions, at least three meaningful words are
    shared and at least 70% of the words either one uses appear in both. A
    message of small words alone, such as a greeting or a thanks, never asks
    again.
  - same place: the same Slack channel or Chat conversation, and either the
    same thread or the new message starts a thread of its own (a question
    asked again at the top of a channel). A reply in another thread is not
    asking again.

  Either way the signal is kept with the request that answered, not the
  message that repeats it. Observing never fails the message it reads: it
  runs in a short transaction of its own, and a failure is logged.
  """
  alias Ryker.Delivery
  alias Ryker.Feedback
  alias Ryker.Ingress
  alias Ryker.Repo
  alias Ryker.RoutingExamples
  alias Ryker.Work
  require Logger

  @people_sources ["slack", "control_plane"]
  @reask_seconds 10 * 60
  # A question answered is looked for this far back; the answer itself must
  # still be within the ten minutes before the new message.
  @question_lookback_seconds 24 * 60 * 60
  @question_limit 50

  @doc "Observes one newly received message, and records what it says about an earlier answer."
  @spec observe(Ingress.Inbox.Entry.t()) :: :ok
  def observe(%Ingress.Inbox.Entry{actor_kind: :user, source_kind: source} = entry)
      when source in @people_sources do
    case Repo.transaction(fn -> observe_locked(entry) end) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> log(reason)
    end
  rescue
    error -> log(error.__struct__)
  end

  def observe(_entry), do: :ok

  # Only an edit that took the words back says something about the answer: a
  # link preview arriving as an edit counted as one and cost an analysis
  # (2026-10-04 review).
  defp observe_locked(%Ingress.Inbox.Entry{event_kind: kind} = entry)
       when kind in [:edit, :delete] do
    if RoutingExamples.takes_back_words?(entry), do: observe_revision(entry), else: :none
  end

  defp observe_locked(%Ingress.Inbox.Entry{event_kind: :message} = entry),
    do: observe_reask(entry)

  defp observe_locked(_entry), do: :none

  defp log(reason) do
    Logger.warning("message feedback not kept: #{inspect(reason, limit: 5)}")
    :ok
  end

  # -- Edited or deleted after the answer ---------------------------------------

  defp observe_revision(entry) do
    case earlier_revisions(entry) do
      [%Ingress.Inbox.Entry{actor_ref: actor} = first | _later] = earlier
      when actor == entry.actor_ref ->
        case answered(earlier, first.occurred_at, entry.occurred_at) do
          {:ok, request} -> record(entry, revision_kind(entry.event_kind), request)
          :none -> :none
        end

      _none_or_someone_else ->
        :none
    end
  end

  defp revision_kind(:edit), do: :message_edited
  defp revision_kind(:delete), do: :message_deleted

  defp earlier_revisions(entry),
    do: entry |> Ingress.Inbox.Entry.Query.earlier_revisions_of() |> Repo.all()

  # The request that answered the message: the latest request any of its
  # revisions joined, once one of its Work replies was delivered after the
  # message was first sent, or else the revision routing answered itself.
  defp answered(revisions, sent_at, before) do
    episode_ids =
      revisions |> Enum.map(& &1.episode_id) |> Enum.reject(&is_nil/1) |> Enum.reverse()

    case Enum.find(episode_ids, &work_reply_between?(&1, sent_at, before)) do
      episode_id when is_binary(episode_id) ->
        {:ok, {:episode, episode_id}}

      nil ->
        case quick_replied(Enum.map(revisions, & &1.id), sent_at, before) do
          input_id when is_binary(input_id) -> {:ok, {:input, input_id}}
          nil -> :none
        end
    end
  end

  defp work_reply_between?(episode_id, from, before) do
    episode_id
    |> Work.Turn.Query.by_episode_id()
    |> Work.Turn.Query.delivered()
    |> Work.Turn.Query.delivered_after(from)
    |> Work.Turn.Query.delivered_before(before)
    |> Repo.exists?()
  end

  defp quick_replied(input_ids, from, before) do
    input_ids
    |> Delivery.RoutingResponse.Query.by_input_ids()
    |> Delivery.RoutingResponse.Query.delivered_messages()
    |> Delivery.RoutingResponse.Query.delivered_after(from)
    |> Delivery.RoutingResponse.Query.delivered_before(before)
    |> Delivery.RoutingResponse.Query.ordered_by_delivered_at_desc()
    |> Delivery.RoutingResponse.Query.limit_to(1)
    |> Delivery.RoutingResponse.Query.select_input_ids()
    |> Repo.one()
  end

  # -- Asked again ----------------------------------------------------------------

  defp observe_reask(entry) do
    words = words(text(entry.content))

    with true <- words.tokens != [],
         [_ | _] = repeated <-
           Enum.filter(earlier_questions(entry), &repeats?(words(text(&1.content)), words)),
         {:ok, request} <- answered_soon(repeated, entry) do
      record(entry, :asked_again, request)
    else
      _not_asked_again -> :none
    end
  end

  # The person's earlier messages in the same conversation, newest first, in a
  # place this message can ask again from: the same thread, or anywhere in
  # the conversation when this message starts a thread of its own.
  defp earlier_questions(entry) do
    since = DateTime.add(entry.occurred_at, -@question_lookback_seconds, :second)

    entry
    |> Ingress.Inbox.Entry.Query.earlier_questions(since, @question_limit)
    |> same_place(entry)
    |> Repo.all()
  end

  defp same_place(query, entry) do
    if top_level?(entry),
      do: query,
      else: Ingress.Inbox.Entry.Query.by_thread_ref(query, entry.destination_thread_ref)
  end

  # A Slack message binds its own timestamp as its thread when it starts one;
  # every Chat message shares its conversation's one thread.
  defp top_level?(%Ingress.Inbox.Entry{source_kind: "slack"} = entry),
    do: entry.source_item_ref == entry.destination_thread_ref

  defp top_level?(_entry), do: false

  # The first of the repeated questions, newest first, that Ryker answered in
  # the ten minutes before this message and after that question was sent.
  defp answered_soon(questions, entry) do
    window_start = DateTime.add(entry.occurred_at, -@reask_seconds, :second)
    episode_ids = questions |> Enum.map(& &1.episode_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    replies = work_replies(episode_ids, window_start, entry.occurred_at)
    quick = quick_replies(Enum.map(questions, & &1.id), window_start, entry.occurred_at)

    Enum.find_value(questions, :none, fn question ->
      cond do
        answered_after?(Map.get(replies, question.episode_id, []), question.occurred_at) ->
          {:ok, {:episode, question.episode_id}}

        answered_after?(Map.get(quick, question.id, []), question.occurred_at) ->
          {:ok, {:input, question.id}}

        true ->
          nil
      end
    end)
  end

  defp answered_after?(delivered, asked_at),
    do: Enum.any?(delivered, &(DateTime.compare(&1, asked_at) == :gt))

  defp work_replies([], _from, _before), do: %{}

  defp work_replies(episode_ids, from, before) do
    episode_ids
    |> Work.Turn.Query.by_episode_ids()
    |> Work.Turn.Query.delivered()
    |> Work.Turn.Query.delivered_since(from)
    |> Work.Turn.Query.delivered_before(before)
    |> Work.Turn.Query.select_episode_deliveries()
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp quick_replies(input_ids, from, before) do
    input_ids
    |> Delivery.RoutingResponse.Query.by_input_ids()
    |> Delivery.RoutingResponse.Query.delivered_messages()
    |> Delivery.RoutingResponse.Query.delivered_since(from)
    |> Delivery.RoutingResponse.Query.delivered_before(before)
    |> Delivery.RoutingResponse.Query.select_input_deliveries()
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # -- Repeating a question ---------------------------------------------------------

  # Small words carry no question of their own: articles, auxiliaries,
  # pronouns, prepositions, greetings and politeness, "what" and "which", and
  # the words people add when they ask again ("still", "again", "now"). "Why",
  # "when", "where", "who" and "how" change the question, so they count.
  @small_words ~w(
    a an the and or but if so of to in on at by for from with into about as than then
    is are was were be been being am do does did done doing can could would should will
    shall may might must have has had i me my mine we us our you your it its this that
    these those there here they them their he him his she her please pls plz thanks
    thank thx ty hey hi hello ok okay yes yeah no not just again still now yet any some
    all also too very really anything something what which whats
  )

  @doc false
  # The words a message uses, for comparing two messages: every word, and the
  # meaningful ones.
  @spec words(String.t()) :: %{tokens: [String.t()], meaningful: MapSet.t()}
  def words(text) when is_binary(text) do
    tokens =
      text
      |> String.replace(~r/<[@#!][^>]*>/u, " ")
      |> String.replace(~r/<https?:[^>]*>|https?:\/\/\S+/u, " ")
      |> String.downcase()
      |> then(&Regex.scan(~r/[\p{L}\p{N}]+/u, &1))
      |> List.flatten()
      |> Enum.filter(&(String.length(&1) > 1 or Regex.match?(~r/\A\p{N}\z/u, &1)))

    %{tokens: tokens, meaningful: tokens |> Enum.reject(&(&1 in @small_words)) |> MapSet.new()}
  end

  @doc false
  # Whether the second message repeats the first, as the moduledoc says.
  @spec repeats?(map(), map()) :: boolean()
  def repeats?(%{tokens: same, meaningful: meaningful}, %{tokens: same})
      when same != [],
      do: MapSet.size(meaningful) > 0

  def repeats?(%{meaningful: earlier}, %{meaningful: later}) do
    shared = MapSet.size(MapSet.intersection(earlier, later))
    union = MapSet.size(MapSet.union(earlier, later))

    cond do
      MapSet.size(earlier) == 0 or MapSet.size(later) == 0 -> false
      earlier == later -> true
      shared >= 3 and shared / union >= 0.7 -> true
      true -> false
    end
  end

  defp text(%{"text" => text}) when is_binary(text), do: text
  defp text(_content), do: ""

  # -- Recording ----------------------------------------------------------------------

  defp record(entry, kind, request) do
    case Feedback.record_in_transaction(%{
           kind: kind,
           actor_ref: entry.actor_ref,
           source: entry.source_kind,
           source_ref: Ingress.Inbox.ref(entry),
           occurred_at: entry.occurred_at,
           request: request
         }) do
      {:ok, recorded} -> recorded
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
