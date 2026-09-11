defmodule Responder.ControlPlane.CurrentInputs do
  @moduledoc "Current source revisions for conversation views; retained model artifacts stay immutable."
  import Ecto.Query
  alias Responder.Ingress.Inbox.Entry

  def latest do
    from(entry in Entry,
      distinct: [entry.execution_mode, entry.native_input_id],
      order_by: [
        asc: entry.execution_mode,
        asc: entry.native_input_id,
        desc: entry.revision,
        desc: entry.inserted_at,
        desc: entry.id
      ]
    )
  end

  def for_episode(id) do
    from(seed in Entry,
      join: current in subquery(latest()),
      on:
        current.native_input_id == seed.native_input_id and
          current.execution_mode == seed.execution_mode,
      where: seed.episode_id == ^id,
      distinct: seed.native_input_id,
      order_by: [asc: seed.native_input_id, asc: seed.occurred_at, asc: seed.id],
      select: %{
        id: current.id,
        occurred_at: seed.occurred_at,
        occurred_at_source: current.occurred_at_source,
        inserted_at: current.inserted_at,
        content: current.content,
        source_envelope: current.source_envelope,
        operational_pruned_at: current.operational_pruned_at,
        event_kind: current.event_kind,
        event_ref: current.event_ref,
        source_item_ref: current.source_item_ref,
        revision: current.revision,
        execution_mode: current.execution_mode,
        destination_transport: current.destination_transport,
        destination_conversation_ref: current.destination_conversation_ref,
        destination_thread_ref: current.destination_thread_ref,
        actor_kind: current.actor_kind,
        actor_ref: current.actor_ref,
        source_kind: current.source_kind,
        source_ref: current.source_ref,
        repository_ref: current.repository_ref
      }
    )
  end
end
