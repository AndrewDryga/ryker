defmodule Ryker.ControlPlane.WorkingCopiesPage do
  @moduledoc """
  The Working copies page: the repository checkouts tasks work in and how
  cleanup treats each one, as Kit rows.

  It reads as every list page does (Andrew, 2026-09-28: "design the bottom
  half properly"): how many copies are in use, ready for cleanup and removed,
  then a compact storage line per worker, then Current or Removed, each a
  list of copies with their confirmed cleanup actions. What is ready for
  cleanup now shows above the current copies only when there is some.
  Nothing here estimates a byte no worker measured: a missing report is
  unknown, never zero. An open page redraws when a copy, its request or a
  worker changes (`subscriptions/0`).
  """
  use Phoenix.Component
  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, Kit, Paths, ShortTime, SlackMarkdown, Units}
  alias Ryker.Slack
  alias Ryker.Wording

  @doc """
  The topics an open Working copies page listens to, as the context functions
  that subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): the worker
  sessions that hold the copies, the requests and learning they work for, and
  the workers whose storage leads the page.
  """
  def subscriptions do
    [
      {Ryker.Work.Custody, :subscribe_sessions, []},
      {Ryker.Episodes, :subscribe_episodes, []},
      {Ryker.Learning, :subscribe_learning, []},
      {Ryker.CoopFleet.ControlPlane.Workers, :subscribe_workers, []}
    ]
  end

  @doc "The page body as HTML, as the route hands it to the shell."
  @spec html(map()) :: binary()
  def html(assigns) do
    assigns
    |> Map.put(:__changed__, nil)
    |> render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  attr(:copies, :map,
    required: true,
    doc: "`WorkspaceProjection.copies/1`: every copy in use, and one page of removed ones"
  )

  attr(:storage, :map, required: true)
  attr(:now, :any, default: nil)
  attr(:view, :string, default: "current", doc: "current, or removed for removed copies")

  defp render(assigns) do
    %{current: current, removed: removed} = assigns.copies
    ready = assigns.storage.preview
    ready_total = Map.get(assigns.storage, :preview_total, length(ready))
    view = if assigns[:view] == "removed", do: "removed", else: "current"

    assigns =
      assigns
      |> assign_new(:now, fn -> nil end)
      |> then(&assign(&1, :now, &1.now || DateTime.utc_now()))
      |> assign(
        view: view,
        current: current,
        removed: removed,
        ready: ready,
        ready_total: ready_total,
        counts: counts(current, ready_total, removed.total)
      )

    ~H"""
    <div class="working-copies-page">
      <Kit.counts label="Working copies" items={@counts} />
      <.storage storage={@storage} now={@now} copies?={@current != []} />
      <Kit.toolbar>
        <Kit.segmented
          label="Which copies"
          options={[
            {"Current", "/working-copies", @view == "current"},
            {"Removed", "/working-copies?view=removed", @view == "removed"}
          ]}
        />
      </Kit.toolbar>
      <%= if @view == "current" do %>
        <section :if={@ready != []} id="ready-for-cleanup" class="working-copies-section">
          <Kit.section_head
            title="Ready for cleanup"
            lede={ready_lede(length(@ready), @ready_total)}
          />
          <Kit.entity_list label="Ready for cleanup">
            <Kit.entity_row
              :for={item <- @ready}
              id={"ready-" <> item.ref}
              icon={:code}
              name={item.repository}
              text={item.reason}
              meta={["ready for " <> duration(item.eligible_age_seconds)]}
            />
          </Kit.entity_list>
        </section>
        <Kit.entity_list :if={@current != []} label="Working copies">
          <.copy :for={row <- @current} row={row} now={@now} />
        </Kit.entity_list>
        <Kit.empty
          :if={@current == []}
          icon={:copy}
          title="No working copies right now"
          text="A copy appears here while a task works in a repository, and stays until cleanup removes it safely."
        />
      <% else %>
        <Kit.entity_list :if={@removed.items != []} label="Removed copies">
          <.copy :for={row <- @removed.items} row={row} now={@now} />
        </Kit.entity_list>
        <Components.pager
          page={@removed.page}
          pages={@removed.pages}
          path={&Paths.query("/working-copies", view: "removed", page: &1)}
          label="Removed copy pages"
          earlier="Newer"
          later="Older"
        />
        <Kit.empty
          :if={@removed.total == 0}
          icon={:copy}
          title="No removed copies yet"
          text="A copy moves here once cleanup removes it."
        />
      <% end %>
    </div>
    """
  end

  # How many copies are in use, ready for cleanup and removed, each opening
  # its view. A count a person should act on is not one of these: a copy that
  # needs attention says so on its row.
  defp counts(current, ready, removed) do
    [
      %{
        value: length(current),
        label: Wording.word(length(current), "copy in use", "copies in use"),
        href: "/working-copies"
      },
      ready > 0 &&
        %{value: ready, label: "ready for cleanup", href: "/working-copies#ready-for-cleanup"},
      %{value: removed, label: "removed", href: "/working-copies?view=removed"}
    ]
    |> Enum.filter(& &1)
  end

  defp ready_lede(shown, total) when total > shown,
    do: "Copies Ryker cleans up next, oldest first: the next #{shown} of #{total}."

  defp ready_lede(_shown, _total), do: "Copies Ryker cleans up next, oldest first."

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
          path={Paths.action("retention", @row.ref, "rearm")}
          label="Resume cleanup"
          tone={:secondary}
        />
        <Components.action_button
          :if={@row.action == :discard_unmerged}
          path={Paths.action("retention", @row.ref, "discard")}
          label="Discard unmerged"
          tone={:danger}
        />
      </:actions>
    </Kit.entity_row>
    """
  end

  # The request the copy was checked out for, by what was asked, linking to
  # its timeline. Two copies of one repository stay distinguishable by it.
  defp request(%{episode_id: id} = row) when is_binary(id) do
    title =
      case Slack.destination_workspace(row[:request_conversation]) do
        nil -> row[:request_title] || "Open the request"
        workspace -> SlackMarkdown.plain(row[:request_title] || "Open the request", workspace)
      end

    request_link(%{__changed__: nil, href: Paths.request(id), title: title})
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

  # "removed after " read before a countdown as "removed after in 10 min" (2026-10-09).
  defp next(%{status: :grace, discard_after: %DateTime{} = at}, now) do
    if DateTime.after?(at, now),
      do: ShortTime.time(%{__changed__: nil, at: at, now: now, prefix: "removed "}),
      else: "removed at the next cleanup"
  end

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

  # An unrecognised code is not a sentence; Failures keeps the saved error.
  defp blocked(_unrecognised),
    do: "cleanup stopped before Ryker could confirm it finished; Failures has the saved error"

  attr(:storage, :map, required: true)
  attr(:now, :any, required: true)
  attr(:copies?, :boolean, required: true)

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
          {size(worker.bytes["protected_bytes"])} in use, {size(worker.bytes["disposable_bytes"])} can be freed {limit(
            @limit
          )}<span :if={worker.measured_at}> · <ShortTime.time
            at={worker.measured_at}
            now={@now}
            prefix="measured "
          /></span><span :if={worker.measurement == :stale}> · this report is out of date</span><span :if={
            is_integer(worker.bytes["unattributed_bytes"]) and worker.bytes["unattributed_bytes"] > 0
          }> · {size(worker.bytes["unattributed_bytes"])} not tied to a copy</span><span :if={
            is_integer(worker.reclaimed_bytes) and worker.reclaimed_bytes > 0
          }> · {size(worker.reclaimed_bytes)} freed so far</span><span :if={
            worker.allocation == "refused"
          }> · not taking new copies ({refusal(worker.refusal_reason)})</span>
        <% end %>
      </p>
      <p :if={not @copies? and space_in_use?(@storage.workers)} class="storage-note">
        No working copy holds this space: it is the workers' shared checkouts, conversations and
        their own data.
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

  # What the worker uses counts its shared checkouts and its own data as well
  # as the copies listed below, so it is never called copies kept.
  defp limit(nil), do: "(no limit set)"
  defp limit(bytes), do: "of " <> size(bytes) <> " allowed"

  defp refusal(nil), do: "reason not reported"
  defp refusal(reason), do: Wording.words(reason)

  defp size(value) when is_integer(value), do: Units.bytes(value)
  defp size(_unmeasured), do: "unknown"

  defp duration(seconds) when is_integer(seconds) and seconds < 60,
    do: Wording.count(seconds, "second")

  defp duration(seconds) when is_integer(seconds) and seconds < 3_600,
    do: Wording.count(div(seconds, 60), "minute")

  defp duration(seconds) when is_integer(seconds) and seconds < 86_400,
    do: Wording.count(div(seconds, 3_600), "hour")

  defp duration(seconds) when is_integer(seconds), do: Wording.count(div(seconds, 86_400), "day")
  defp duration(_unknown), do: "an unknown time"

  defp space_in_use?(workers) do
    Enum.any?(workers, fn worker ->
      is_integer(worker.bytes["protected_bytes"]) and worker.bytes["protected_bytes"] > 0
    end)
  end
end
