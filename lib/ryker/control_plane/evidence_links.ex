defmodule Ryker.ControlPlane.EvidenceLinks do
  @moduledoc "Links completed citations to their exact saved observation in the same timeline."

  alias Ryker.StateTools.FixedTools

  def attach(steps, events, turns, records) do
    turns = Enum.group_by(turns, &{&1.episode_id, &1.session_id, &1.coop_turn_id})
    records = Enum.group_by(records, & &1.turn_id)

    {_, links} =
      Enum.reduce(events, {%{}, %{}}, fn event, {started, links} ->
        key =
          {event.episode_id, event.session_id, event.coop_turn_id, event.payload["tool_call_id"]}

        case event.kind do
          "tool.started" ->
            {Map.put(started, key, event.payload["input"]), links}

          "tool.completed" ->
            {input, started} = Map.pop(started, key)
            link = saved_evidence(event, input, turns, records)
            {started, if(link, do: Map.put(links, "activity-" <> event.id, link), else: links)}

          _ ->
            {started, links}
        end
      end)

    Enum.map(steps, fn step ->
      case links[step.id] do
        nil -> step
        link -> Map.put(step, :saved_evidence, link)
      end
    end)
  end

  defp saved_evidence(
         %{
           payload: %{"status" => "completed", "tool_call_id" => call_id},
           coop_turn_id: coop_turn_id,
           admission_input_id: nil
         } = event,
         %{"server" => "responder-state", "tool" => "cite_source", "arguments" => args},
         turns,
         records
       )
       when is_binary(call_id) and call_id != "" and is_binary(coop_turn_id) and
              coop_turn_id != "" and is_map(args) do
    with [turn] <- turns[{event.episode_id, event.session_id, event.coop_turn_id}],
         [record] <-
           Enum.filter(records[turn.id] || [], fn record ->
             FixedTools.citation_record?(record, turn, args) &&
               DateTime.compare(record.inserted_at, event.occurred_at) != :gt
           end) do
      "#event-record-" <> record.id
    else
      _ -> nil
    end
  end

  defp saved_evidence(_event, _input, _turns, _records), do: nil
end
