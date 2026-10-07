defmodule Ryker.WorkExamples.Example.Query do
  @moduledoc "Settled Work turns kept as examples, for every read of `work_examples`."
  import Ecto.Query
  alias Ryker.Work.{OwningTurn, Turn}
  alias Ryker.WorkExamples.Example

  def all, do: from(examples in Example, as: :work_examples)

  def by_turn_id(queryable \\ all(), turn_id),
    do: where(queryable, [work_examples: x], x.turn_id == ^turn_id)

  def kept(queryable \\ all()), do: where(queryable, [work_examples: x], is_nil(x.forgotten_at))

  @doc "Examples answered in `conversation_ref` or quoting it."
  def by_conversation(queryable \\ all(), conversation_ref) do
    where(
      queryable,
      [work_examples: x],
      x.conversation_ref == ^conversation_ref or
        fragment("? @> ARRAY[?]::text[]", x.conversation_refs, ^conversation_ref)
    )
  end

  @doc "Examples asked in any of `identities` or whose routing quoted any of the messages `keys` names."
  def from_sources_or_messages(queryable \\ all(), identities, keys) do
    where(
      queryable,
      [work_examples: x],
      fragment("? && ?::text[]", x.source_identities, ^identities) or
        fragment("? && ?::text[]", x.message_keys, ^keys)
    )
  end

  def ordered_by_settled_at(queryable),
    do: order_by(queryable, [work_examples: x], asc: x.settled_at, asc: x.id)

  @doc """
  The ids of turns ready to be copied, oldest first and at most `limit`:
  settled within the last `window_seconds` with their bodies still kept, no
  example yet, and nothing their request started still running.
  """
  def settled_turns(limit, window_seconds) do
    from(turn in Turn,
      as: :episode_work_turns,
      where: turn.status == :settled and is_nil(turn.operational_pruned_at),
      where: not is_nil(turn.submission) and not is_nil(turn.candidate),
      where:
        fragment(
          "? > clock_timestamp() - (? * interval '1 second')",
          turn.updated_at,
          ^window_seconds
        ),
      where:
        not exists(
          from(example in Example, where: example.turn_id == parent_as(:episode_work_turns).id)
        ),
      where:
        not exists(
          from(work in subquery(OwningTurn.Query.work_rest()),
            where: work.episode_id == parent_as(:episode_work_turns).episode_id and work.running
          )
        ),
      order_by: [asc: turn.updated_at, asc: turn.id],
      limit: ^limit,
      select: turn.id
    )
  end
end
