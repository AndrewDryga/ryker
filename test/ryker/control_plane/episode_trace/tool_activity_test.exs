defmodule Ryker.ControlPlane.EpisodeTrace.ToolActivityTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.EpisodeCausality
  alias Ryker.ControlPlane.EpisodeTrace.ToolActivity
  alias Ryker.Work.ActivityEvent

  @start ~U[2026-10-06 08:00:00.000000Z]

  test "a completed call replaces its start at the time it completed" do
    events = [
      started("a", 0),
      started("b", 1),
      completed("a", 2),
      completed("lost", 3)
    ]

    assert [
             %{title: "Run b", state: "started"},
             %{title: "Run a", state: "completed", duration_ms: 2_000},
             %{title: "Tool completion recorded", state: "completed"}
           ] = steps(events)
  end

  # Each completion searched every step folded so far for the start it
  # replaced, so a run's timeline took time in the square of its tool calls
  # and a long task's page grew slower to open with every call it made
  # (2026-10-04 review). Reductions count work rather than time, so the
  # comparison holds however loaded the machine is: four times the calls
  # cost about four times the work, where the old fold cost about sixteen.
  test "a run's tool calls fold in work proportional to their number" do
    small = reductions(fn -> steps(calls(400)) end)
    large = reductions(fn -> steps(calls(1_600)) end)

    assert large < small * 6,
           "1,600 calls cost #{Float.round(large / small, 1)} times the work of 400"
  end

  defp calls(count) do
    Enum.map(1..count, &started("call-#{&1}", &1)) ++
      Enum.map(1..count, &completed("call-#{&1}", count + &1))
  end

  defp steps(events),
    do: ToolActivity.steps(events, EpisodeCausality.index([], [], []), MapSet.new())

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    fun.()
    {:reductions, after_run} = Process.info(self(), :reductions)
    after_run - before
  end

  defp started(call, second) do
    event("tool.started", second, %{
      "kind" => "execute",
      "title" => "Run #{call}",
      "tool_call_id" => call
    })
  end

  defp completed(call, second) do
    event("tool.completed", second, %{
      "kind" => "execute",
      "status" => "completed",
      "tool_call_id" => call
    })
  end

  defp event(kind, second, payload) do
    %ActivityEvent{
      id: Ecto.UUID.generate(),
      kind: kind,
      session_id: "session",
      coop_turn_id: "turn",
      remote_event_id: Ecto.UUID.generate(),
      occurred_at: DateTime.add(@start, second, :second),
      payload: payload
    }
  end
end
