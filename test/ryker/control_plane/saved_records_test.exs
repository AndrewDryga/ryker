defmodule Ryker.ControlPlane.SavedRecordsTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.SavedRecords
  alias Ryker.Records.Record
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

  test "a saved citation is told by its observation's card alone, matched by turn and full call identity",
       c do
    # Andrew, 2026-09-28, of "Citation saved · View recorded evidence ↑": "one
    # of card is just to link other one?" In this retained HAProxy run the
    # completion omitted its response; the durable host operation and full
    # claim hash still prove the exact citation, so its card goes and the
    # evidence card above it stands for the call. Earlier events stay as they were.
    assert fold(c) == [hd(c.steps)]
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
      assert fold(%{c | events: [start, finish]}) == c.steps
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
      assert fold(%{c | record: record}) == c.steps
    end

    for turn <- [
          %{c.turn | session_id: Ecto.UUID.generate()},
          %{c.turn | coop_turn_id: "another-turn"},
          %{c.turn | episode_id: Ecto.UUID.generate()}
        ] do
      assert fold(%{c | turn: turn}) == c.steps
    end

    assert SavedRecords.fold(c.steps, c.events, [c.turn, c.turn], [c.record]) == c.steps
    assert SavedRecords.fold(c.steps, c.events, [c.turn], [c.record, c.record]) == c.steps
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
      assert fold(%{c | events: events}) == c.steps
    end

    assert SavedRecords.fold(c.steps, c.events, [c.turn], []) == c.steps
    assert SavedRecords.fold(c.steps, c.events, [], [c.record]) == c.steps
  end

  test "idempotent calls fold into one existing citation without claiming another creation",
       c do
    [start, finish] = c.events

    repeated =
      [start, finish]
      |> Enum.map(
        &%{&1 | id: Ecto.UUID.generate(), occurred_at: DateTime.add(&1.occurred_at, 1, :second)}
      )

    steps = c.steps ++ Enum.map(repeated, &%{id: "activity-" <> &1.id, at: &1.occurred_at})
    result = SavedRecords.fold(steps, c.events ++ repeated, [c.turn], [c.record])

    # Both calls are told by the one evidence card; neither claims another.
    assert result == [
             hd(c.steps),
             %{id: "activity-" <> hd(repeated).id, at: hd(repeated).occurred_at}
           ]
  end

  test "missing remote call and turn identities never establish a citation link", c do
    for id <- [nil, ""] do
      events = Enum.map(c.events, &put_in(&1.payload["tool_call_id"], id))
      assert fold(%{c | events: events}) == c.steps
      events = Enum.map(c.events, &%{&1 | coop_turn_id: id})
      assert fold(%{c | events: events, turn: %{c.turn | coop_turn_id: id}}) == c.steps
    end
  end

  # Andrew, 2026-09-28, of the infrastructure review's timeline: "buggy af".
  # Every finding showed twice in a row, as "Finding · Unexplained" and again
  # as "Finding recorded" with the same words, because the call that saved a
  # finding kept a card of its own beside the finding's.
  test "a saved finding is told by its finding card alone, not again by its call" do
    fixture = File.read!("testdata/control_plane/finding-record-fold.json") |> Jason.decode!()
    events = Enum.map(fixture["activities"], &load(ActivityEvent, &1))
    turn = load(Turn, fixture["turn"])
    record = load(Record, fixture["record"])
    completed = Enum.find(events, &(&1.kind == "tool.completed"))
    steps = [%{id: "activity-" <> completed.id, at: completed.occurred_at}]

    assert SavedRecords.fold(steps, events, [turn], [record]) == []

    # Another finding of the same turn leaves the call its own card.
    other = %{record | operation_id: "host:" <> String.duplicate("0", 64)}
    assert SavedRecords.fold(steps, events, [turn], [other]) == steps
  end

  defp fold(c), do: SavedRecords.fold(c.steps, c.events, [c.turn], [c.record])

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
