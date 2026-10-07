defmodule Ryker.Feedback.Signal.Query do
  @moduledoc "Feedback people gave on Ryker's answers, for every read of `answer_feedback`."
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Feedback.Signal
  alias Ryker.Ingress.Inbox.Entry

  def all, do: from(signals in Signal, as: :answer_feedback)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [answer_feedback: s], s.episode_id == ^episode_id)

  @doc "The signal of `kind` its source named `source_ref`."
  def by_source(queryable \\ all(), kind, source_ref) do
    where(
      queryable,
      [answer_feedback: s],
      s.kind == ^kind and s.source_ref == ^source_ref
    )
  end

  def by_input_id(queryable \\ all(), input_id),
    do: where(queryable, [answer_feedback: s], s.input_id == ^input_id)

  @doc """
  Reactions on messages in `conversation_ref`. A message's name is its
  platform's, unique only within its conversation (a Slack timestamp), so a
  reaction is read through its request's conversation.
  """
  def reactions_in(conversation_ref) do
    all()
    |> join(:left, [answer_feedback: s], i in Entry,
      on: i.id == s.input_id,
      as: :ingress_inbox_entries
    )
    |> join(:left, [answer_feedback: s], e in Episode,
      on: e.id == s.episode_id,
      as: :episode_kernel_episodes
    )
    |> where(
      [answer_feedback: s],
      s.kind in [:reaction_added, :reaction_removed] and not is_nil(s.message_ref)
    )
    |> where(
      [ingress_inbox_entries: i, episode_kernel_episodes: e],
      i.destination_conversation_ref == ^conversation_ref or
        e.destination_conversation_ref == ^conversation_ref
    )
  end

  def occurred_between(queryable \\ all(), from, to) do
    where(
      queryable,
      [answer_feedback: s],
      s.occurred_at >= ^from and s.occurred_at < ^to
    )
  end

  def in_categories(queryable, categories),
    do: where(queryable, [answer_feedback: s], s.category in ^categories)

  def count_by_category(queryable) do
    queryable
    |> group_by([answer_feedback: s], s.category)
    |> select([answer_feedback: s], {s.category, count()})
  end

  def on_messages(queryable, message_refs),
    do: where(queryable, [answer_feedback: s], s.message_ref in ^message_refs)

  def recorded_since(queryable, since),
    do: where(queryable, [answer_feedback: s], s.inserted_at >= ^since)

  # Two signals the source says happened at the same moment read in the order
  # Ryker recorded them.
  def ordered_by_occurred_at_desc(queryable) do
    order_by(queryable, [answer_feedback: s],
      desc: s.occurred_at,
      desc: s.inserted_at,
      desc: s.id
    )
  end

  def ordered_by_occurred_at(queryable) do
    order_by(queryable, [answer_feedback: s],
      asc: s.occurred_at,
      asc: s.inserted_at,
      asc: s.id
    )
  end

  def select_reactions(queryable) do
    select(
      queryable,
      [answer_feedback: s],
      {s.message_ref, s.kind, s.actor_ref, s.value, s.occurred_at}
    )
  end

  def select_message_refs(queryable),
    do: queryable |> distinct(true) |> select([answer_feedback: s], s.message_ref)

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
