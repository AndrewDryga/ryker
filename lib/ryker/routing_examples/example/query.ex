defmodule Ryker.RoutingExamples.Example.Query do
  @moduledoc "Routing decisions kept as examples, for every read of `routing_examples`."
  use Ryker, :query
  alias Ryker.Admission
  alias Ryker.Delivery
  alias Ryker.Ingress
  alias Ryker.RoutingExamples.Example
  alias Ryker.Work

  def all, do: from(examples in Example, as: :routing_examples)

  def by_input_id(queryable \\ all(), input_id),
    do: where(queryable, [routing_examples: x], x.input_id == ^input_id)

  def by_input_ids(queryable \\ all(), input_ids),
    do: where(queryable, [routing_examples: x], x.input_id in ^input_ids)

  def kept(queryable \\ all()),
    do: where(queryable, [routing_examples: x], is_nil(x.forgotten_at))

  @doc "Examples answered in `conversation_ref` or quoting it."
  def by_conversation(queryable \\ all(), conversation_ref) do
    where(
      queryable,
      [routing_examples: x],
      x.conversation_ref == ^conversation_ref or
        fragment("? @> ARRAY[?]::text[]", x.conversation_refs, ^conversation_ref)
    )
  end

  @doc "Examples from any of `identities` or quoting any of the messages `keys` names."
  def from_sources_or_messages(queryable \\ all(), identities, keys) do
    where(
      queryable,
      [routing_examples: x],
      x.source_identity in ^identities or fragment("? && ?::text[]", x.message_keys, ^keys)
    )
  end

  def ordered_by_decided_at(queryable),
    do: order_by(queryable, [routing_examples: x], asc: x.decided_at, asc: x.id)

  @doc """
  The ids of messages ready to be copied, oldest first and at most `limit`:
  decided within the last `window_seconds`, their routing turn completed
  and committed with its bodies still kept, no example yet, and nothing
  they started still running.
  """
  def settled_decisions(limit, window_seconds, skip) do
    from(input in Ingress.Inbox.Entry,
      as: :ingress_inbox_entries,
      join: attempt in Admission.Attempt,
      on: attempt.input_id == input.id and attempt.generation == input.execution_generation,
      where: input.status == :decided and is_nil(input.operational_pruned_at),
      where: input.id not in ^skip,
      where:
        fragment(
          "? > clock_timestamp() - (? * interval '1 second')",
          input.updated_at,
          ^window_seconds
        ),
      where: attempt.phase == "committed" and is_nil(attempt.operational_pruned_at),
      where: fragment("(?::jsonb)->>'state' = 'completed'", attempt.response),
      where: fragment("(?::jsonb)->>'assistant_message' IS NOT NULL", attempt.response),
      where: fragment("(?::jsonb)->>'prompt' IS NOT NULL", attempt.submission),
      where: fragment("(?::jsonb)->'output_schema' IS NOT NULL", attempt.submission),
      where:
        not exists(
          from(example in Example,
            where: example.input_id == parent_as(:ingress_inbox_entries).id
          )
        ),
      where:
        not exists(
          from(work in subquery(Work.OwningTurn.Query.work_rest()),
            where:
              work.episode_id == parent_as(:ingress_inbox_entries).episode_id and work.running
          )
        ),
      where:
        not exists(
          from(response in Delivery.RoutingResponse,
            where:
              response.input_id == parent_as(:ingress_inbox_entries).id and
                response.status == :pending
          )
        ),
      order_by: [asc: input.updated_at, asc: input.id],
      limit: ^limit,
      select: input.id
    )
  end
end
