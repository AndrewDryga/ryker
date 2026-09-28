defmodule Ryker.ControlPlane.SavedCitations do
  @moduledoc """
  A completed citation whose saved observation is on the same timeline is
  told by that observation's card alone.

  The citation's own card once said "Citation saved · View recorded evidence ↑"
  and nothing else: a card whose only content was a link to the card above it
  (Andrew, 2026-09-28: "one of card is just to link other one?"). A citation
  that failed, stopped, or saved nothing this timeline shows keeps its card.
  """

  alias Ryker.StateTools.FixedTools

  def fold(steps, events, turns, records) do
    turns = Enum.group_by(turns, &{&1.episode_id, &1.session_id, &1.coop_turn_id})
    records = Enum.group_by(records, & &1.turn_id)

    {_, saved} =
      Enum.reduce(events, {%{}, %{}}, fn event, {started, saved} ->
        key =
          {event.episode_id, event.session_id, event.coop_turn_id, event.payload["tool_call_id"]}

        case event.kind do
          "tool.started" ->
            {Map.put(started, key, event.payload["input"]), saved}

          "tool.completed" ->
            {input, started} = Map.pop(started, key)
            record = saved_record(event, input, turns, records)

            {started,
             if(record, do: Map.put(saved, "activity-" <> event.id, record), else: saved)}

          _ ->
            {started, saved}
        end
      end)

    Enum.reject(steps, &Map.has_key?(saved, &1.id))
  end

  defp saved_record(
         %{
           payload: %{"status" => "completed", "tool_call_id" => call_id},
           coop_turn_id: coop_turn_id,
           admission_input_id: nil
         } = event,
         %{"server" => server, "tool" => "cite_source", "arguments" => args},
         turns,
         records
       )
       when server in ["controller-tools", "responder-state"] and is_binary(call_id) and
              call_id != "" and is_binary(coop_turn_id) and
              coop_turn_id != "" and is_map(args) do
    with [turn] <- turns[{event.episode_id, event.session_id, event.coop_turn_id}],
         [record] <-
           Enum.filter(records[turn.id] || [], fn record ->
             FixedTools.citation_record?(record, turn, args) &&
               DateTime.compare(record.inserted_at, event.occurred_at) != :gt
           end) do
      record.id
    else
      _ -> nil
    end
  end

  defp saved_record(_event, _input, _turns, _records), do: nil
end
