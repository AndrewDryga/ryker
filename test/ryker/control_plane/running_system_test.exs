defmodule Ryker.ControlPlane.RunningSystemTest do
  @moduledoc """
  Andrew, 2026-09-28, of Settings › Advanced: "Tasks that change code ·
  Supported — that must be always supported so why we show it?" and "What is
  running … collapsibles inside collapsibles, and information right now is
  not very practical". What is running is one plain card with what support
  needs: the version, and each worker's state, slots and disk against the
  line where it stops taking new work.
  """
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias Ryker.ControlPlane.RunningSystem
  alias Ryker.CoopFleet.Worker

  @now ~U[2026-09-28 19:00:00.000000Z]

  test "what is running shows the version and each worker's state, slots and disk, with nothing folded" do
    document = render(true, [worker()])

    assert LazyHTML.query(document, "details") |> Enum.count() == 0
    assert LazyHTML.query(document, "#code-editing") |> Enum.count() == 0

    card = LazyHTML.query(document, "#running-now") |> text()
    assert card =~ "Ryker 0.1.0-g6816a614"
    assert card =~ "Taking work"
    assert card =~ "Coop v9.0.0-506-gaaf66dd9"
    assert card =~ "Work slots 3 of 4 free"
    assert card =~ "Disk 23 GiB free · new work stops below 4.1 GiB free"
    refute card =~ "New work is stopped"
  end

  test "a worker that stopped taking new work for disk says so and where to free space" do
    storage = %{
      worker().storage
      | "allocation" => "refused",
        "refusal_reason" => "reserve_exhausted"
    }

    card =
      render(true, [%{worker() | storage: storage}]) |> LazyHTML.query("#running-now") |> text()

    assert card =~ "New work is stopped: its disk reached the space it keeps free for cleanup."
    assert card =~ "Working copies"
  end

  test "a worker quiet for minutes reads as not connected, and one never seen says so" do
    quiet = %{worker() | last_seen_at: DateTime.add(@now, -600, :second)}
    assert render(true, [quiet]) |> text() =~ "Not connected"

    never = %{worker() | last_seen_at: nil, storage: nil, capacity: %{}}
    card = render(true, [never]) |> text()
    assert card =~ "Never connected"
    assert card =~ "Disk Not reported yet"

    assert render(true, []) |> text() =~ "No worker has connected yet"
  end

  # Placement stops giving a worker work after a minute without a poll, while
  # this card waited two, so for a minute it said "Taking work" about a worker
  # that was given none (2026-10-04 review). Every view shares one heartbeat.
  test "a worker past the heartbeat placement uses reads as not connected" do
    quiet = %{worker() | last_seen_at: DateTime.add(@now, -90, :second)}
    assert render(true, [quiet]) |> text() =~ "Not connected"

    seconds = Worker.heartbeat_seconds()
    current = %{worker() | last_seen_at: DateTime.add(@now, -seconds, :second)}
    refute render(true, [current]) |> text() =~ "Not connected"
  end

  test "tasks that change code show only when they cannot run, with what to check" do
    unsupported = render(false, [worker()])
    code = LazyHTML.query(unsupported, "#code-editing") |> text()
    assert code =~ "Tasks that change code cannot run"
    assert code =~ "scripts/compose.sh status"
  end

  defp worker do
    %Worker{
      id: "ryker-compose",
      state: :eligible,
      build_version: "v9.0.0-506-gaaf66dd9",
      capacity: %{"session_slots_free" => 3, "session_slots_total" => 4},
      last_seen_at: DateTime.add(@now, -5, :second),
      storage: %{
        "allocation" => "open",
        "capacity_bytes" => 88_852_135_936,
        "free_bytes" => 24_741_605_376,
        "high_watermark_bytes" => 84_409_529_140,
        "refusal_reason" => nil
      }
    }
  end

  defp render(supported, workers) do
    %{version: "0.1.0-g6816a614", workers: workers, supported: supported, now: @now}
    |> card()
    |> LazyHTML.from_fragment()
  end

  defp text(document), do: document |> LazyHTML.text() |> String.replace(~r/\s+/, " ")

  defp card(view), do: render_component(&RunningSystem.card/1, view)
end
