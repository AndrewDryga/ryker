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

  import Ecto.Query

  require Logger

  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Feedback
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.Turn

  @people_sources ["slack", "control_plane"]
  @reask_seconds 10 * 60
  # A question answered is looked for this far back; the answer itself must
  # still be within the ten minutes before the new message.
  @question_lookback_seconds 24 * 60 * 60
  @question_limit 50

  @doc "Observes one newly received message, and records what it says about an earlier answer."
  @spec observe(Entry.t()) :: :ok
  def observe(%Entry{actor_kind: :user, source_kind: source} = entry)
      when source in @people_sources do
    case Repo.transaction(fn -> observe_locked(entry) end) do
      {:ok, _outcome} -> :ok
      {:error, reason} -> log(reason)
    end
  rescue
    error -> log(error.__struct__)
  end

  def observe(_entry), do: :ok

  defp observe_locked(%Entry{event_kind: kind} = entry) when kind in [:edit, :delete],
    do: observe_revision(entry)

  defp observe_locked(%Entry{event_kind: :message} = entry), do: observe_reask(entry)
  defp observe_locked(_entry), do: :none

  defp log(reason) do
    Logger.warning("message feedback not kept: #{inspect(reason, limit: 5)}")
    :ok
  end

  # -- Edited or deleted after the answer ---------------------------------------

  defp observe_revision(entry) do
    case earlier_revisions(entry) do
      [%Entry{actor_ref: actor} = first | _later] = earlier when actor == entry.actor_ref ->
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

  defp earlier_revisions(entry) do
    Repo.all(
      from(earlier in Entry,
        where:
          earlier.source_kind == ^entry.source_kind and earlier.source_ref == ^entry.source_ref and
            earlier.native_input_id == ^entry.native_input_id and
            earlier.execution_mode == ^entry.execution_mode and
            earlier.revision < ^entry.revision and earlier.id != ^entry.id,
        order_by: [asc: earlier.revision, asc: earlier.inserted_at, asc: earlier.id],
        select:
          struct(earlier, [:id, :actor_ref, :episode_id, :occurred_at, :revision, :event_kind])
      )
    )
  end

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
    Repo.exists?(
      from(turn in Turn,
        where:
          turn.episode_id == ^episode_id and not is_nil(turn.delivered_at) and
            turn.delivered_at > ^from and turn.delivered_at < ^before
      )
    )
  end

  defp quick_replied(input_ids, from, before) do
    Repo.one(
      from(response in RoutingResponse,
        where:
          response.input_id in ^input_ids and response.kind == :message and
            response.status == :delivered and response.delivered_at > ^from and
            response.delivered_at < ^before,
        order_by: [desc: response.delivered_at, desc: response.id],
        limit: 1,
        select: response.input_id
      )
    )
  end

  # -- Asked again ----------------------------------------------------------------

  defp observe_reask(entry) do
    words = words(text(entry.content))

    with true <- words.tokens != [],
         [_ | _] = repeated <-
           entry |> earlier_questions() |> Enum.filter(&repeats?(words(text(&1.content)), words)),
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

    from(question in Entry,
      where:
        question.source_kind == ^entry.source_kind and question.source_ref == ^entry.source_ref and
          question.occurred_at >= ^since and question.occurred_at < ^entry.occurred_at and
          question.actor_kind == :user and question.actor_ref == ^entry.actor_ref and
          question.destination_transport == ^entry.destination_transport and
          question.destination_conversation_ref == ^entry.destination_conversation_ref and
          question.execution_mode == ^entry.execution_mode and
          question.event_kind in [:message, :edit] and question.id != ^entry.id and
          is_nil(question.operational_pruned_at),
      order_by: [desc: question.occurred_at, desc: question.id],
      limit: @question_limit,
      select:
        struct(question, [
          :id,
          :content,
          :episode_id,
          :occurred_at,
          :destination_thread_ref
        ])
    )
    |> same_place(entry)
    |> Repo.all()
  end

  defp same_place(query, entry) do
    if top_level?(entry),
      do: query,
      else:
        from(question in query,
          where: question.destination_thread_ref == ^entry.destination_thread_ref
        )
  end

  # A Slack message binds its own timestamp as its thread when it starts one;
  # every Chat message shares its conversation's one thread.
  defp top_level?(%Entry{source_kind: "slack"} = entry),
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
    Repo.all(
      from(turn in Turn,
        where:
          turn.episode_id in ^episode_ids and not is_nil(turn.delivered_at) and
            turn.delivered_at >= ^from and turn.delivered_at < ^before,
        select: {turn.episode_id, turn.delivered_at}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp quick_replies(input_ids, from, before) do
    Repo.all(
      from(response in RoutingResponse,
        where:
          response.input_id in ^input_ids and response.kind == :message and
            response.status == :delivered and response.delivered_at >= ^from and
            response.delivered_at < ^before,
        select: {response.input_id, response.delivered_at}
      )
    )
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
           source_ref: Inbox.ref(entry),
           occurred_at: entry.occurred_at,
           request: request
         }) do
      {:ok, recorded} -> recorded
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
