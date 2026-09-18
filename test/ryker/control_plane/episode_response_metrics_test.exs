defmodule Ryker.ControlPlane.EpisodeResponseMetricsTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.EpisodeResponseMetrics
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Work.Turn

  @start ~U[2026-09-18 12:00:00Z]

  test "a late review cannot inflate a two-minute response" do
    episode = episode(:complete, DateTime.add(@start, 20, :minute))
    input = input("one", @start)
    turn = turn(["event:one"], delivered_at: DateTime.add(@start, 2, :minute))

    metrics = EpisodeResponseMetrics.project(episode, [input], [turn], %{"event:one" => input.id})

    assert metrics.wall == %{state: :complete, milliseconds: 120_000, reason: nil}
    assert metrics.messages == %{received: 1, sent: 1, total: 2}

    assert metrics.response == %{
             average_ms: 120_000,
             expected: 1,
             maximum_ms: 120_000,
             measured: 1,
             minimum_ms: 120_000
           }
  end

  test "one outcome selected from several messages emits one response sample per message" do
    first = input("first", @start)
    second = input("second", DateTime.add(@start, 60))

    completed =
      turn(["event:first", "event:second"], delivered_at: DateTime.add(@start, 180))

    metrics =
      EpisodeResponseMetrics.project(
        episode(:complete, DateTime.add(@start, 900)),
        [first, second],
        [completed],
        %{"event:first" => first.id, "event:second" => second.id}
      )

    assert metrics.messages == %{received: 2, sent: 1, total: 3}

    assert metrics.response == %{
             average_ms: 150_000,
             expected: 2,
             maximum_ms: 180_000,
             measured: 2,
             minimum_ms: 120_000
           }
  end

  test "silent terminal results use acceptance while active and historical unmapped messages stay untimed" do
    first = input("first", @start)
    second = input("second", DateTime.add(@start, 30))

    silent =
      turn(["event:first"],
        accepted_at: DateTime.add(@start, 90),
        delivery_document: %{"delivery" => "none"}
      )

    historical = turn(nil, accepted_at: DateTime.add(@start, 120))

    metrics =
      EpisodeResponseMetrics.project(
        episode(:complete, DateTime.add(@start, 1_200)),
        [first, second],
        [silent, historical],
        %{"event:first" => first.id}
      )

    assert metrics.wall == %{state: :complete, milliseconds: 90_000, reason: nil}
    assert metrics.messages == %{received: 2, sent: 0, total: 2}
    assert metrics.response.measured == 1
    assert metrics.response.expected == 2
    assert metrics.response.minimum_ms == 90_000
  end

  test "missing and backwards timestamps are unknown, never zero" do
    missing = input("missing", nil)
    backwards = input("backwards", DateTime.add(@start, 60))

    turn =
      turn(["event:missing", "event:backwards"], delivered_at: @start)

    metrics =
      EpisodeResponseMetrics.project(
        episode(:complete, DateTime.add(@start, 1_200)),
        [missing, backwards],
        [turn],
        %{"event:missing" => missing.id, "event:backwards" => backwards.id}
      )

    assert metrics.wall == %{
             state: :unknown,
             milliseconds: nil,
             reason: "The first message time was not recorded."
           }

    assert metrics.response == %{
             average_ms: nil,
             expected: 2,
             maximum_ms: nil,
             measured: 0,
             minimum_ms: nil
           }
  end

  test "active work reports a so-far wall span without inventing a completed response" do
    input = input("active", @start)

    metrics =
      EpisodeResponseMetrics.project(
        episode(:working, DateTime.add(@start, 5, :minute)),
        [input],
        [turn(["event:active"])],
        %{"event:active" => input.id},
        now: DateTime.add(@start, 75)
      )

    assert metrics.wall == %{state: :active, milliseconds: 75_000, reason: nil}
    assert metrics.messages == %{received: 1, sent: 0, total: 1}
    assert metrics.response.measured == 0
    assert metrics.response.expected == 1
  end

  defp episode(state, updated_at),
    do: %Episode{
      id: Ecto.UUID.generate(),
      key: "episode:metrics",
      state: state,
      updated_at: updated_at
    }

  defp input(name, occurred_at),
    do: %Entry{id: Ecto.UUID.generate(), dedupe_key: "input:#{name}", occurred_at: occurred_at}

  defp turn(refs, options \\ []) do
    defaults = [
      id: Ecto.UUID.generate(),
      selected_input_refs: refs,
      delivery_document: %{"delivery" => "reply", "message" => "Done"},
      accepted_at: nil,
      delivered_at: nil
    ]

    struct!(Turn, Keyword.merge(defaults, options))
  end
end
