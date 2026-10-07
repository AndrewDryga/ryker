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
       %{events: events, record: record, steps: steps, turn: turn} do
    # Andrew, 2026-09-28, of "Citation saved · View recorded evidence ↑": "one
    # of card is just to link other one?" In this retained HAProxy run the
    # completion omitted its response; the durable host operation and full
    # claim hash still prove the exact citation, so its card goes and the
    # evidence card above it stands for the call. Earlier events stay as they were.
    assert SavedRecords.fold(steps, events, [turn], [record]) == [hd(steps)]
  end

  test "similar prose and a shared operation slot never hide a different observation",
       %{events: events, record: record, steps: steps, turn: turn} do
    for {key, value} <- [
          {"observation", "A changed observation in the same operation slot"},
          {"supersedes", ["record:evidence:different"]},
          {"relation", "context"},
          {"source_ref", "slack-source:different"},
          {"subject", "A similar subject"}
        ] do
      [start, finish] = events
      start = put_in(start.payload["input"]["arguments"][key], value)
      assert SavedRecords.fold(steps, [start, finish], [turn], [record]) == steps
    end
  end

  test "only the same unambiguous host turn and work session can link a record",
       %{events: events, record: record, steps: steps, turn: turn} do
    for record <- [
          %{record | episode_id: Ecto.UUID.generate()},
          %{record | turn_id: Ecto.UUID.generate()},
          %{record | operation_id: "host:different"},
          %{record | kind: "finding"},
          %{record | payload: %{}},
          %{record | inserted_at: DateTime.add(List.last(events).occurred_at, 1, :second)}
        ] do
      assert SavedRecords.fold(steps, events, [turn], [record]) == steps
    end

    for turn <- [
          %{turn | session_id: Ecto.UUID.generate()},
          %{turn | coop_turn_id: "another-turn"},
          %{turn | episode_id: Ecto.UUID.generate()}
        ] do
      assert SavedRecords.fold(steps, events, [turn], [record]) == steps
    end

    assert SavedRecords.fold(steps, events, [turn, turn], [record]) == steps
    assert SavedRecords.fold(steps, events, [turn], [record, record]) == steps
  end

  test "failed, unmatched, admission and missing calls retain their full standalone cards",
       %{events: events, record: record, steps: steps, turn: turn} do
    [start, finish] = events

    for events <- [
          [start, put_in(finish.payload["status"], "failed")],
          [start, put_in(finish.payload["tool_call_id"], "other-call")],
          [start, %{finish | admission_input_id: Ecto.UUID.generate()}],
          [put_in(start.payload["input"]["server"], "another-server"), finish],
          [put_in(start.payload["input"]["arguments"], nil), finish],
          [finish]
        ] do
      assert SavedRecords.fold(steps, events, [turn], [record]) == steps
    end

    assert SavedRecords.fold(steps, events, [turn], []) == steps
    assert SavedRecords.fold(steps, events, [], [record]) == steps
  end

  test "idempotent calls fold into one existing citation without claiming another creation",
       %{events: events, record: record, steps: steps, turn: turn} do
    [start, finish] = events

    repeated =
      [start, finish]
      |> Enum.map(
        &%{&1 | id: Ecto.UUID.generate(), occurred_at: DateTime.add(&1.occurred_at, 1, :second)}
      )

    steps = steps ++ Enum.map(repeated, &%{id: "activity-" <> &1.id, at: &1.occurred_at})
    result = SavedRecords.fold(steps, events ++ repeated, [turn], [record])

    # Both calls are told by the one evidence card; neither claims another.
    assert result == [
             hd(steps),
             %{id: "activity-" <> hd(repeated).id, at: hd(repeated).occurred_at}
           ]
  end

  test "missing remote call and turn identities never establish a citation link",
       %{events: events, record: record, steps: steps, turn: turn} do
    for id <- [nil, ""] do
      events = Enum.map(events, &put_in(&1.payload["tool_call_id"], id))
      assert SavedRecords.fold(steps, events, [turn], [record]) == steps
      events = Enum.map(events, &%{&1 | coop_turn_id: id})
      assert SavedRecords.fold(steps, events, [%{turn | coop_turn_id: id}], [record]) == steps
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
