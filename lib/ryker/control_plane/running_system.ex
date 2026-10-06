defmodule Ryker.ControlPlane.RunningSystem do
  @moduledoc """
  What is running, at the bottom of Settings › Advanced: the Ryker version, and
  for each worker whether it is taking work, its Coop version, its free work
  slots and how much disk it has before it stops taking new work.

  Andrew, 2026-09-28: the card it replaces listed every loaded setting under
  collapsibles inside a collapsible (ten parts of Ryker that always read
  "Configured", the integrations and retention again, eighteen tool names) and
  was "not very practical". A worker's disk is what actually stops work, so
  it is here in its own numbers (`Ryker.CoopFleet.Protocol` storage report).
  Tasks that change code are always supported on a working installation, so
  that card shows only when they are not, with what to check.
  """

  use Phoenix.Component

  import Ecto.Query

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Kit, ShortTime}
  alias Ryker.CoopFleet.Worker
  alias Ryker.Repo
  alias Ryker.Work.CodeEditingSetup

  @doc "What the page shows, read afresh."
  @spec fetch() :: map()
  def fetch do
    %{
      version: to_string(Application.spec(:ryker, :vsn) || "unknown"),
      workers: Repo.all(from(worker in Worker, order_by: [asc: worker.id])),
      supported: CodeEditingSetup.checkpoint_supported?(),
      now: Repo.now!()
    }
  end

  @doc "The card as HTML, ready for the settings page's body."
  @spec html(map()) :: String.t()
  def html(view) do
    view
    |> Map.put(:__changed__, nil)
    |> render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp render(assigns) do
    ~H"""
    <Kit.section_card
      :if={!@supported}
      id="code-editing"
      class="code-editing-setup"
      title="Tasks that change code"
      lede="Tasks that change code cannot run on this installation right now."
    >
      <div class="settings-problem">
        <p>
          Ryker cannot save and restore the copy of the code such a task works in. Docker Compose
          installations set this up on their own: check <code>scripts/compose.sh status</code>
          and <code>scripts/compose.sh logs</code>, then restart the installation.
        </p>
      </div>
    </Kit.section_card>
    <Kit.section_card
      id="running-now"
      title="Running now"
      lede="What this installation runs, for support and troubleshooting."
    >
      <Kit.facts facts={[{"Ryker", @version}]} />
      <p :if={@workers == []} class="settings-lede">
        No worker has connected yet, so no work can run.
      </p>
      <div :for={worker <- @workers} class="running-worker" id={"running-worker-" <> worker.id}>
        <h3>{worker.id}</h3>
        <Kit.facts facts={worker_facts(worker, @now)} />
        <p :if={refused?(worker)} class="settings-problem">
          New work is stopped: {refusal(worker.storage)} It starts again once cleanup frees space;
          <a href="/working-copies">Working copies</a>
          shows what can be freed.
        </p>
      </div>
    </Kit.section_card>
    """
  end

  defp worker_facts(worker, now) do
    [
      {"State", state(worker, now)},
      {"Coop", worker.build_version},
      {"Work slots", slots(worker.capacity)},
      {"Disk", disk(worker.storage)}
    ]
  end

  defp state(%Worker{last_seen_at: nil}, _now), do: word(:off, "Never connected")

  defp state(%Worker{state: state, last_seen_at: seen}, now) do
    if DateTime.diff(now, seen) > Worker.heartbeat_seconds() do
      assigns = %{__changed__: nil, seen: seen, now: now}

      ~H"""
      <Kit.state tone={:warn} word="Not connected" />
      <ShortTime.time at={@seen} now={@now} prefix=" · last seen " />
      """
    else
      state_word(state)
    end
  end

  defp state_word(state) when state in [:eligible, :busy], do: word(:on, "Taking work")
  defp state_word(:draining), do: word(:warn, "Finishing its work, taking no new work")
  defp state_word(:needs_auth), do: word(:bad, "Needs a model sign-in")
  defp state_word(:revoked), do: word(:off, "Removed")
  defp state_word(_state), do: word(:off, "Offline")

  defp word(tone, text) do
    assigns = %{__changed__: nil, tone: tone, text: text}
    ~H"<Kit.state tone={@tone} word={@text} />"
  end

  defp slots(%{"session_slots_total" => total, "session_slots_free" => free})
       when is_integer(total) and is_integer(free),
       do: "#{free} of #{total} free"

  defp slots(_capacity), do: nil

  # The worker's own volume and the line where it stops taking new work.
  defp disk(%{"free_bytes" => free, "capacity_bytes" => capacity, "high_watermark_bytes" => stop})
       when is_integer(free) and is_integer(capacity) and is_integer(stop),
       do: "#{gb(free)} free · new work stops below #{gb(capacity - stop)} free"

  defp disk(_storage), do: "Not reported yet"

  defp refused?(%Worker{storage: %{"allocation" => "refused"}}), do: true
  defp refused?(_worker), do: false

  defp refusal(%{"refusal_reason" => "reserve_exhausted"}),
    do: "its disk reached the space it keeps free for cleanup."

  defp refusal(%{"refusal_reason" => "protected_storage_exceeds_budget"}),
    do: "working copies Ryker must keep fill its disk."

  defp refusal(_storage), do: "its disk is full."

  defp gb(bytes), do: :erlang.float_to_binary(bytes / 1_000_000_000, decimals: 1) <> " GB"
end
