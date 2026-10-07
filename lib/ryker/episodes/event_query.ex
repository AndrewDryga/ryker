defmodule Ryker.Episodes.EventQuery do
  @moduledoc "What happened in each request, for every read of `episode_kernel_events`."
  import Ecto.Query
  alias Ryker.Episodes.Event

  def all, do: from(events in Event, as: :episode_kernel_events)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_kernel_events: e], e.episode_id == ^episode_id)

  @doc "The admissions of the inputs `dedupe_keys` names."
  def admitted_inputs(queryable, dedupe_keys) do
    where(
      queryable,
      [episode_kernel_events: e],
      e.kind == :input_admitted and e.dedupe_key in ^dedupe_keys
    )
  end

  @doc """
  The admissions from `sequence` on, and of the inputs still queued, which
  `queued_refs` names: what a turn has not answered yet.
  """
  def admitted_since_or_queued(queryable, sequence, queued_refs) do
    where(
      queryable,
      [episode_kernel_events: e],
      e.kind == :input_admitted and (e.sequence >= ^sequence or e.dedupe_key in ^queued_refs)
    )
  end

  def select_payloads(queryable), do: select(queryable, [episode_kernel_events: e], e.payload)

  def newest_first(queryable),
    do: order_by(queryable, [episode_kernel_events: e], desc: e.sequence)
end
