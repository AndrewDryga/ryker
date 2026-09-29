defmodule Ryker.ControlPlane.SavedRecords do
  @moduledoc """
  A completed call whose saved record is on the same timeline is told by that
  record's card alone: a citation by its evidence, a finding by the finding,
  a goal and its progress by the goal.

  The citation's own card once said "Citation saved · View recorded evidence ↑"
  and nothing else: a card whose only content was a link to the card above it
  (Andrew, 2026-09-28: "one of card is just to link other one?"). Every
  finding then showed twice in a row, as "Finding · Unexplained" and as
  "Finding recorded" with the same words, and every goal as a record and a
  call. A call that failed, stopped, or saved nothing this timeline shows
  keeps its card.
  """

  alias Ryker.StateTools.FixedTools

  # The calls whose records are told by their own cards.
  @writers ~w(cite_source record_finding plan_goal update_goal)

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
         %{"server" => server, "tool" => tool, "arguments" => args},
         turns,
         records
       )
       when server in ["controller-tools", "responder-state"] and tool in @writers and
              is_binary(call_id) and
              call_id != "" and is_binary(coop_turn_id) and
              coop_turn_id != "" and is_map(args) do
    with [turn] <- turns[{event.episode_id, event.session_id, event.coop_turn_id}],
         [record] <-
           Enum.filter(records[turn.id] || [], fn record ->
             FixedTools.written_by?(record, turn, tool, args) &&
               DateTime.compare(record.inserted_at, event.occurred_at) != :gt
           end) do
      record.id
    else
      _ -> nil
    end
  end

  defp saved_record(_event, _input, _turns, _records), do: nil
end
