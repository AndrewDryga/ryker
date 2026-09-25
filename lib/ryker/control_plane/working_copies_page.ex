defmodule Ryker.ControlPlane.WorkingCopiesPage do
  @moduledoc """
  The Working copies page: the repository checkouts tasks work in and how
  cleanup treats each one, as Kit rows.

  A compact storage line per worker comes first, then the copies with their
  confirmed cleanup actions, what is ready for cleanup now, and the removed
  copies behind one closed disclosure. Nothing here estimates a byte no
  worker measured: a missing report is unknown, never zero.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, Kit, ShortTime, SlackMarkdown, SlackNames}

  @gib 1_073_741_824

  @doc "The page body as HTML, as the route hands it to the shell."
  @spec html(map()) :: binary()
  def html(assigns) do
    assigns
    |> Map.put(:__changed__, nil)
    |> render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  attr(:rows, :list, required: true)
  attr(:storage, :map, required: true)
  attr(:now, :any, default: nil)

  def render(assigns) do
    # Learning sessions share the cleanup custody but hold no checkout; the
    # Learning page lists them.
    rows =
      Enum.filter(
        assigns.rows,
        &(Map.get(&1, :execution_kind) != :learning and is_binary(Map.get(&1, :repository)))
      )

    assigns =
      assigns
      |> assign_new(:now, fn -> nil end)
      |> then(&assign(&1, :now, &1.now || DateTime.utc_now()))
      |> assign(
        current: Enum.reject(rows, &(&1.status == :discarded)),
        removed: Enum.filter(rows, &(&1.status == :discarded)),
        ready:
          Enum.filter(assigns.storage.preview, &(&1.kind == :work and is_binary(&1.repository)))
      )

    ~H"""
    <div class="working-copies-page">
      <.storage storage={@storage} now={@now} />
      <Kit.entity_list :if={@current != []} label="Working copies">
        <.copy :for={row <- @current} row={row} now={@now} />
      </Kit.entity_list>
      <Kit.empty
        :if={@current == []}
        title="No working copies right now."
        text="A copy appears here while a task works in a repository, and stays until cleanup removes it safely."
      />
      <section id="ready-for-cleanup" class="working-copies-section">
        <Kit.section_head
          title="Ready for cleanup"
          lede="Copies Ryker can clean up now, oldest first."
        />
        <Kit.entity_list :if={@ready != []} label="Ready for cleanup">
          <Kit.entity_row
            :for={item <- @ready}
            id={"ready-" <> item.ref}
            name={item.repository}
            text={item.reason}
            meta={["ready for " <> duration(item.eligible_age_seconds)]}
          />
        </Kit.entity_list>
        <Kit.empty :if={@ready == []} title="Nothing is ready for cleanup right now." />
      </section>
      <details :if={@removed != []} id="removed-copies" class="working-copies-history">
        <summary>Removed copies ({length(@removed)})</summary>
        <Kit.entity_list label="Removed copies">
          <.copy :for={row <- @removed} row={row} now={@now} />
        </Kit.entity_list>
      </details>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:now, :any, required: true)

  defp copy(assigns) do
    ~H"""
    <Kit.entity_row
      id={"copy-" <> @row.ref}
      icon={:code}
      name={@row.repository}
      state={state(@row.status)}
      text={request(@row)}
      meta={[
        next(@row, @now),
        ShortTime.time(%{__changed__: nil, at: @row.updated_at, now: @now, prefix: "updated "})
      ]}
    >
      <:actions :if={@row.action}>
        <Components.action_button
          :if={@row.action == :rearm}
          path={"/actions/retention/" <> encode(@row.ref) <> "/rearm"}
          label="Resume cleanup"
          tone={:secondary}
        />
        <Components.action_button
          :if={@row.action == :discard_unmerged}
          path={"/actions/retention/" <> encode(@row.ref) <> "/discard"}
          label="Discard unmerged"
          tone={:danger}
        />
      </:actions>
      <:details>
        <details id={"copy-" <> @row.ref <> "-details"} class="entity-details">
          <summary>Details</summary>
          <dl class="entity-facts">
            <div>
              <dt>Working copy ID</dt>
              <dd><code>{@row.ref}</code></dd>
            </div>
            <div :if={@row[:state]}>
              <dt>Request</dt>
              <dd>{Components.label(@row.state)}</dd>
            </div>
          </dl>
        </details>
      </:details>
    </Kit.entity_row>
    """
  end

  # The request the copy was checked out for, by what was asked, linking to
  # its timeline. Two copies of one repository stay distinguishable by it.
  defp request(%{episode_ref: ref} = row) when is_binary(ref) do
    title =
      case SlackNames.workspace_from_destination(row[:request_conversation]) do
        nil -> row[:request_title] || "Open the request"
        workspace -> SlackMarkdown.plain(row[:request_title] || "Open the request", workspace)
      end

    request_link(%{__changed__: nil, href: "/timeline/" <> encode(ref), title: title})
  end

  defp request(_row), do: nil

  defp request_link(assigns), do: ~H|<a href={@href}>{@title}</a>|

  defp state(:active), do: {:busy, "In use"}
  defp state(:grace), do: {:off, "Kept for follow-up"}
  defp state(:retained), do: {:warn, "Changes kept"}
  defp state(:blocked), do: {:warn, "Cleanup needs attention"}
  defp state(:discarded), do: {:off, "Removed"}
  defp state(_close_plan_or_discard_pending), do: {:busy, "Cleaning up"}

  # What cleanup does next, and when.
  defp next(%{status: :active}, _now), do: "cleanup starts when the task ends"

  defp next(%{status: :grace, discard_after: %DateTime{} = at}, now),
    do: ShortTime.time(%{__changed__: nil, at: at, now: now, prefix: "removed after "})

  defp next(%{status: :grace}, _now), do: "removed when the follow-up window ends"

  defp next(%{status: :retained, summary: "unpublished_unmerged"}, _now),
    do: "has commits that were never merged, kept until you discard them"

  defp next(%{status: :retained, summary: "dirty"}, _now),
    do: "has uncommitted changes, kept until they are safe to remove"

  defp next(%{status: :retained}, _now), do: "kept until cleanup is safe"
  defp next(%{status: :blocked, summary: code}, _now), do: blocked(code)
  defp next(%{status: :close_pending}, _now), do: "closing the worker session"
  defp next(%{status: :plan_pending}, _now), do: "checking what is safe to remove"
  defp next(%{status: :discard_pending}, _now), do: "removing the copy"
  defp next(_removed, _now), do: nil

  defp blocked("coop_error"),
    do: "the worker could not finish this step; check the saved error before resuming"

  defp blocked(code) when code in ~w(coop_unavailable coop_transport_error),
    do: "the worker could not be reached; check its connection, then resume"

  defp blocked("coop_worker_command_timeout"),
    do: "the worker did not answer in time; resume to try again"

  defp blocked("coop_session_replacement_required"),
    do: "the worker that held this copy can no longer take it back"

  # An unrecognised code is not a sentence; Failures keeps the saved error.
  defp blocked(_unrecognised),
    do: "cleanup stopped before Ryker could confirm it finished; Failures has the saved error"

  attr(:storage, :map, required: true)
  attr(:now, :any, required: true)

  defp storage(assigns) do
    assigns =
      assign(assigns,
        limit: assigns.storage.budget[:disposable_bytes_limit],
        target: assigns.storage.budget[:reclaim_target_seconds]
      )

    ~H"""
    <section id="storage" class="working-copies-storage" aria-label="Storage">
      <p :if={@storage.workers == []} class="storage-line">
        <span class="connection-dot" data-tone="off" aria-hidden="true"></span>
        No worker has reported storage yet, so how much space copies use is unknown.
      </p>
      <p :for={worker <- @storage.workers} class="storage-line" id={"storage-" <> worker.id}>
        <span class="connection-dot" data-tone={worker_tone(worker)} aria-hidden="true"></span>
        <strong>{worker.id}</strong>
        <%= if worker.measurement == :unknown do %>
          has not reported storage yet.
        <% else %>
          {gib(worker.bytes["protected_bytes"])} kept, {gib(worker.bytes["disposable_bytes"])} disposable {limit(
            @limit
          )}<span :if={worker.measured_at}> · <ShortTime.time
            at={worker.measured_at}
            now={@now}
            prefix="measured "
          /></span><span :if={worker.measurement == :stale}> · this report is out of date</span><span :if={
            is_integer(worker.bytes["unattributed_bytes"]) and worker.bytes["unattributed_bytes"] > 0
          }> · {gib(worker.bytes["unattributed_bytes"])} not tied to a copy</span><span :if={
            is_integer(worker.reclaimed_bytes) and worker.reclaimed_bytes > 0
          }> · {gib(worker.reclaimed_bytes)} freed so far</span><span :if={
            worker.allocation == "refused"
          }> · not taking new copies ({refusal(worker.refusal_reason)})</span>
        <% end %>
      </p>
      <p :if={@target} class="storage-note">
        Ryker cleans up copies that are ready within {duration(@target)}.
      </p>
    </section>
    """
  end

  defp worker_tone(%{allocation: "refused"}), do: "warn"
  defp worker_tone(%{measurement: :fresh}), do: "on"
  defp worker_tone(_unknown_or_stale), do: "off"

  defp limit(nil), do: "(no limit set)"
  defp limit(bytes), do: "of " <> gib(bytes)

  defp refusal(nil), do: "reason not reported"
  defp refusal(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp gib(value) when is_integer(value) do
    amount =
      (value / @gib)
      |> Float.round(2)
      |> :erlang.float_to_binary(decimals: 2)
      |> String.replace(~r/\.?0+$/, "")

    amount <> " GiB"
  end

  defp gib(_unmeasured), do: "unknown"

  defp duration(seconds) when is_integer(seconds) and seconds < 60,
    do: plural(seconds, "second")

  defp duration(seconds) when is_integer(seconds) and seconds < 3_600,
    do: plural(div(seconds, 60), "minute")

  defp duration(seconds) when is_integer(seconds) and seconds < 86_400,
    do: plural(div(seconds, 3_600), "hour")

  defp duration(seconds) when is_integer(seconds), do: plural(div(seconds, 86_400), "day")
  defp duration(_unknown), do: "an unknown time"

  defp plural(1, unit), do: "1 #{unit}"
  defp plural(count, unit), do: "#{count} #{unit}s"

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
