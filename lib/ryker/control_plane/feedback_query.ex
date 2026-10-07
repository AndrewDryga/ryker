defmodule Ryker.ControlPlane.FeedbackQuery do
  @moduledoc """
  What the Feedback page reads beyond one signal's own row
  (`Ryker.ControlPlane.FeedbackProjection`): search across the request a
  signal is about, the newest signals of each category, and the requests and
  messages the signals name.
  """
  import Ecto.Query
  require Ryker.ControlPlane.CurrentInputQuery
  alias Ryker.ControlPlane.CurrentInputQuery
  alias Ryker.Episodes.RoutingDigest
  alias Ryker.Feedback.Signal
  alias Ryker.Ingress.Inbox.Entry

  @doc """
  The signals of `query` whose note or emoji, or the name of the request they
  are about (the title Ryker gave it, or the message routing answered by
  itself), contains `pattern`.
  """
  def matching(query, pattern) do
    from([answer_feedback: signal] in query,
      left_join: digest in RoutingDigest,
      on: digest.episode_id == signal.episode_id,
      left_join: input in Entry,
      on: input.id == signal.input_id,
      where:
        ilike(signal.note, ^pattern) or ilike(signal.value, ^pattern) or
          ilike(digest.title, ^pattern) or
          fragment("(?::jsonb ->> 'text') ILIKE ?", input.content, ^pattern)
    )
  end

  @doc "The `count` newest signals of `query` in each category, newest first."
  def newest_per_category(query, count) do
    ranked =
      from([answer_feedback: signal] in query,
        select: %{
          id: signal.id,
          rank:
            over(row_number(),
              partition_by: signal.category,
              order_by: [desc: signal.occurred_at, desc: signal.inserted_at, desc: signal.id]
            )
        }
      )

    from(signal in Signal,
      join: ranked in subquery(ranked),
      on: ranked.id == signal.id,
      where: ranked.rank <= ^count,
      order_by: [desc: signal.occurred_at, desc: signal.inserted_at, desc: signal.id]
    )
  end

  @doc "How many signals of `query` came in each UTC day in each category, as `{day, category, count}`."
  def counts_by_day(query) do
    from([answer_feedback: signal] in query,
      group_by: [fragment("date(?)", signal.occurred_at), signal.category],
      select: {fragment("date(?)", signal.occurred_at), signal.category, count()}
    )
  end

  @doc """
  The messages `input_ids` names, each as it reads now, as `{id, transport,
  conversation_ref, preview}`.
  """
  def message_previews(input_ids) do
    from(entry in Entry,
      where: entry.id in ^input_ids,
      select:
        {entry.id, entry.destination_transport, entry.destination_conversation_ref,
         CurrentInputQuery.visible_preview(
           entry.operational_pruned_at,
           entry.event_kind,
           entry.content
         )}
    )
  end
end
