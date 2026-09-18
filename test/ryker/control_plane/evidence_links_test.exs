defmodule Ryker.ControlPlane.EvidenceLinksTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.EvidenceLinks
  alias Ryker.State.Record
  alias Ryker.Work.{ActivityEvent, Turn}

  setup do
    fixture = File.read!("testdata/control_plane/oom-evidence-link.json") |> Jason.decode!()
    events = Enum.map(fixture["activities"], &load(ActivityEvent, &1))
    steps = Enum.map(events, &%{id: "activity-" <> &1.id, at: &1.occurred_at})

    %{
      events: events,
      steps: steps,
      turn: load(Turn, fixture["turn"]),
      record: load(Record, fixture["record"])
    }
  end

  test "the real citation links by owning turn and full call identity without rewriting earlier events",
       c do
    # In this retained HAProxy run the completion omitted its response. The
    # durable host operation and full claim hash still prove the exact citation.
    [started, completed] = attach(c)
    assert completed.saved_evidence == "#event-record-" <> c.record.id
    assert completed.at == List.last(c.events).occurred_at
    assert started == hd(c.steps)
    assert Map.delete(completed, :saved_evidence) == List.last(c.steps)
  end

  test "similar prose and a shared operation slot never hide a different observation", c do
    for {key, value} <- [
          {"observation", "A changed observation in the same operation slot"},
          {"supersedes", ["record:evidence:different"]},
          {"relation", "context"},
          {"source_ref", "slack-source:different"},
          {"subject", "A similar subject"}
        ] do
      [start, finish] = c.events
      start = put_in(start.payload["input"]["arguments"][key], value)
      assert attach(%{c | events: [start, finish]}) == c.steps
    end
  end

  test "only the same unambiguous host turn and work session can link a record", c do
    for record <- [
          %{c.record | episode_id: Ecto.UUID.generate()},
          %{c.record | turn_id: Ecto.UUID.generate()},
          %{c.record | operation_id: "host:different"},
          %{c.record | kind: "finding"},
          %{c.record | payload: %{}},
          %{c.record | inserted_at: DateTime.add(List.last(c.events).occurred_at, 1, :second)}
        ] do
      assert attach(%{c | record: record}) == c.steps
    end

    for turn <- [
          %{c.turn | session_id: Ecto.UUID.generate()},
          %{c.turn | coop_turn_id: "another-turn"},
          %{c.turn | episode_id: Ecto.UUID.generate()}
        ] do
      assert attach(%{c | turn: turn}) == c.steps
    end

    assert EvidenceLinks.attach(c.steps, c.events, [c.turn, c.turn], [c.record]) == c.steps
    assert EvidenceLinks.attach(c.steps, c.events, [c.turn], [c.record, c.record]) == c.steps
  end

  test "failed, unmatched, admission and missing calls retain their full standalone cards", c do
    [start, finish] = c.events

    for events <- [
          [start, put_in(finish.payload["status"], "failed")],
          [start, put_in(finish.payload["tool_call_id"], "other-call")],
          [start, %{finish | admission_input_id: Ecto.UUID.generate()}],
          [put_in(start.payload["input"]["server"], "another-server"), finish],
          [put_in(start.payload["input"]["arguments"], nil), finish],
          [finish]
        ] do
      assert attach(%{c | events: events}) == c.steps
    end

    assert EvidenceLinks.attach(c.steps, c.events, [c.turn], []) == c.steps
    assert EvidenceLinks.attach(c.steps, c.events, [], [c.record]) == c.steps
  end

  test "idempotent calls can point to one existing citation without claiming another creation",
       c do
    [start, finish] = c.events

    repeated =
      [start, finish]
      |> Enum.map(
        &%{&1 | id: Ecto.UUID.generate(), occurred_at: DateTime.add(&1.occurred_at, 1, :second)}
      )

    steps = c.steps ++ Enum.map(repeated, &%{id: "activity-" <> &1.id, at: &1.occurred_at})
    result = EvidenceLinks.attach(steps, c.events ++ repeated, [c.turn], [c.record])
    assert Enum.count(result, &Map.has_key?(&1, :saved_evidence)) == 2

    assert result
           |> Enum.filter(&Map.has_key?(&1, :saved_evidence))
           |> Enum.map(& &1.saved_evidence)
           |> Enum.uniq() == ["#event-record-" <> c.record.id]
  end

  test "missing remote call and turn identities never establish a citation link", c do
    for id <- [nil, ""] do
      events = Enum.map(c.events, &put_in(&1.payload["tool_call_id"], id))
      assert attach(%{c | events: events}) == c.steps
      events = Enum.map(c.events, &%{&1 | coop_turn_id: id})
      assert attach(%{c | events: events, turn: %{c.turn | coop_turn_id: id}}) == c.steps
    end
  end

  defp attach(c), do: EvidenceLinks.attach(c.steps, c.events, [c.turn], [c.record])

  defp load(module, fields) do
    attributes =
      for field <- module.__schema__(:fields),
          Map.has_key?(fields, Atom.to_string(field)),
          into: %{} do
        value = fields[Atom.to_string(field)]

        value =
          if value && field in [:occurred_at, :inserted_at, :updated_at],
            do: DateTime.from_naive!(NaiveDateTime.from_iso8601!(value), "Etc/UTC"),
            else: value

        {field, value}
      end

    struct!(module, attributes)
  end
end
