defmodule Ryker.Feedback do
  @moduledoc """
  What people told Ryker about its answers, kept with the request each answer
  belongs to (`answer_feedback`, `Ryker.Feedback.Signal`).

  Andrew, 2026-09-27: "Do we have feedbacks, self-improvement loop, and data
  collection …?" and "use that sentiment as indirect feedback channel, plus
  let users see feedback by category in UI". Ryker kept operator reviews and
  the corrections it gave the model, and nothing about how people took an
  answer. Each signal here is one of:

  - a reaction added to or taken back from one of Ryker's messages, in Slack
    or Chat (`Ryker.Episodes.Reactions`);
  - the person editing or deleting their message after Ryker answered it,
    or asking the same thing again soon after the answer
    (`Ryker.Feedback.Messages`, from the message as it is received);
  - how routing read the person's next message about the answer before it,
    satisfied, neutral, frustrated or angry, with its reason
    (`Ryker.Admission`, when it commits the routing decision); and
  - an operator marking how the request ended as reviewed, with the note
    (`Ryker.Operator.EpisodeReviews`).

  Recording is idempotent per source event: one event gives at most one
  signal of a kind. A signal is announced once its transaction commits, on
  this module's topic (`subscribe_feedback/0`) and on the request's own
  topics, so the Feedback page and the request's Timeline redraw. Feedback
  is operational data: it expires with the operational horizon
  (`Ryker.Retention.Data`), and with its request when that goes first.
  """

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Feedback.Signal
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo

  @type request :: {:episode, Ecto.UUID.t()} | {:input, Ecto.UUID.t()}
  @type result :: %{signal: Signal.t(), status: :recorded | :duplicate}

  @doc "Records one signal in a transaction of its own; see `record_in_transaction/1`."
  @spec record(map()) :: {:ok, result()} | {:error, term()}
  def record(attributes) do
    Repo.transaction(fn ->
      case record_in_transaction(attributes) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Records one signal inside the caller's transaction.

  `attributes` names the signal's `kind`, `value` and `note`, who gave it
  (`actor_ref`, as its `source` names people), when (`occurred_at`), the
  event it came from (`source_ref`) and its `request`, `{:episode, id}` or
  `{:input, id}`. The category is derived here, once. The request row is
  held while the signal is written, so retention cannot remove it between
  the check and the insert; a request that is already gone records nothing
  (`{:error, :feedback_request_not_found}`). The same kind from the same
  event again returns the signal recorded the first time, as `:duplicate`.
  """
  @spec record_in_transaction(map()) :: {:ok, result()} | {:error, term()}
  def record_in_transaction(%{request: request} = attributes) do
    with {:ok, request_ids} <- request_ids(request),
         {:ok, signal} <- valid_signal(attributes, request_ids),
         :ok <- hold_request(signal) do
      insert(signal)
    end
  end

  def record_in_transaction(_attributes), do: {:error, {:invalid_feedback, :request}}

  @doc """
  The Feedback page's category for a signal, frustrated first
  (`Ryker.Feedback.Signal.categories/0`): an angry or frustrated sentiment,
  or a reaction that says so, is frustrated; asking again and changing the
  message after the answer are their own; a satisfied sentiment or a
  reaction that says so is satisfied; a review is a review; everything else,
  including a reaction taken back, is neutral.
  """
  @spec category(atom(), String.t() | nil) :: atom()
  def category(:sentiment, feeling) when feeling in ["frustrated", "angry"], do: :frustrated
  def category(:sentiment, "satisfied"), do: :satisfied
  def category(:sentiment, _feeling), do: :neutral
  def category(:reaction_added, emoji), do: reaction_category(emoji)
  def category(:reaction_removed, _emoji), do: :neutral
  def category(:asked_again, _value), do: :asked_again
  def category(kind, _value) when kind in [:message_edited, :message_deleted], do: :edited
  def category(:reviewed, _value), do: :reviewed

  # What a reaction says without its context. Most emoji say nothing about how
  # an answer landed (eyes is "I'm looking"), so only these two short lists
  # count either way.
  @satisfied_emoji ~w(
    +1 thumbsup heart heart_eyes green_heart blue_heart purple_heart yellow_heart orange_heart
    tada partying_face white_check_mark heavy_check_mark raised_hands clap pray ok_hand 100
    rocket star star-struck sparkles muscle smile smiley grinning slightly_smiling_face blush
  )
  @frustrated_emoji ~w(
    -1 thumbsdown x confused disappointed rage angry face_with_rolling_eyes unamused cry sob
    weary tired_face facepalm face_palm man-facepalming woman-facepalming person_facepalming
    slightly_frowning_face white_frowning_face frowning worried persevere confounded triumph
  )

  defp reaction_category(emoji) when emoji in @satisfied_emoji, do: :satisfied
  defp reaction_category(emoji) when emoji in @frustrated_emoji, do: :frustrated
  defp reaction_category(_emoji), do: :neutral

  @doc """
  The feedback on one request, oldest first, at most `limit` of the newest,
  for its Timeline.
  """
  @spec for_request(request(), pos_integer()) :: [Signal.t()]
  def for_request(request, limit \\ 100)

  def for_request({:episode, id}, limit) when is_binary(id),
    do: newest(from(signal in Signal, where: signal.episode_id == ^id), limit)

  def for_request({:input, id}, limit) when is_binary(id),
    do: newest(from(signal in Signal, where: signal.input_id == ^id), limit)

  def for_request(_request, _limit), do: []

  defp newest(query, limit) do
    from(signal in query, order_by: [desc: signal.occurred_at, desc: signal.id], limit: ^limit)
    |> Repo.all()
    |> Enum.reverse()
  end

  # -- Recording ---------------------------------------------------------------

  defp request_ids({:episode, id}) when is_binary(id),
    do: uuid(id, fn id -> {:ok, %{episode_id: id, input_id: nil}} end)

  defp request_ids({:input, id}) when is_binary(id),
    do: uuid(id, fn id -> {:ok, %{episode_id: nil, input_id: id}} end)

  defp request_ids(_request), do: {:error, {:invalid_feedback, :request}}

  defp uuid(value, next) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> next.(id)
      :error -> {:error, {:invalid_feedback, :request}}
    end
  end

  defp valid_signal(attributes, request_ids) do
    kind = Map.get(attributes, :kind)
    value = Map.get(attributes, :value)

    attributes
    |> Map.take([:kind, :value, :note, :actor_ref, :source, :source_ref, :occurred_at])
    |> Map.merge(request_ids)
    |> Map.merge(%{id: Ecto.UUID.generate(), category: category_of(kind, value)})
    |> Signal.changeset()
    |> Ecto.Changeset.apply_action(:insert)
    |> case do
      {:ok, signal} -> {:ok, signal}
      {:error, changeset} -> {:error, {:invalid_feedback, invalid_fields(changeset)}}
    end
  end

  defp category_of(kind, value) do
    if kind in Signal.kinds(), do: category(kind, value)
  end

  defp invalid_fields(changeset),
    do: changeset.errors |> Keyword.keys() |> Enum.uniq() |> Enum.sort()

  # FOR KEY SHARE keeps the request from being deleted until this transaction
  # ends, without blocking anything that only updates it.
  defp hold_request(%Signal{episode_id: id}) when is_binary(id),
    do: held(from(episode in Episode, where: episode.id == ^id, select: episode.id))

  defp hold_request(%Signal{input_id: id}) when is_binary(id),
    do: held(from(entry in Entry, where: entry.id == ^id, select: entry.id))

  defp held(query) do
    case Repo.one(from(row in query, lock: "FOR KEY SHARE")) do
      nil -> {:error, :feedback_request_not_found}
      _id -> :ok
    end
  end

  @columns [
    :id,
    :kind,
    :value,
    :note,
    :category,
    :actor_ref,
    :source,
    :source_ref,
    :occurred_at,
    :episode_id,
    :input_id
  ]

  defp insert(%Signal{} = signal) do
    case Repo.insert_all(Signal, [Map.take(signal, @columns)],
           on_conflict: :nothing,
           conflict_target: [:kind, :source_ref],
           returning: true
         ) do
      {1, [recorded]} ->
        announce(recorded)
        {:ok, %{signal: recorded, status: :recorded}}

      {0, []} ->
        {:ok,
         %{
           signal: Repo.get_by!(Signal, kind: signal.kind, source_ref: signal.source_ref),
           status: :duplicate
         }}
    end
  end

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to feedback: `{:feedback_recorded, signal_id}` once a
  signal about one of Ryker's answers is recorded and that has committed.
  The request it is about hears it on its own topics too.
  """
  def subscribe_feedback, do: Ryker.PubSub.subscribe(feedback_topic())

  def unsubscribe_feedback, do: Ryker.PubSub.unsubscribe(feedback_topic())

  defp feedback_topic, do: "feedback"

  defp announce(%Signal{id: id} = signal) do
    Episodes.broadcast_episode_updated(signal.episode_id)
    if signal.input_id, do: Inbox.broadcast_input_updated(signal.input_id)

    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(feedback_topic(), {:feedback_recorded, id})
    end)
  end
end
