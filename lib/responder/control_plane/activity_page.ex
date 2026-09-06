defmodule Responder.ControlPlane.ActivityPage do
  alias Responder.ControlPlane.RequestFilters
  alias Responder.ControlPlane.SlackMarkdown
  alias Responder.ControlPlane.SlackNames
  alias Responder.ControlPlane.UsageProjection
  @moduledoc "The conversation-first activity inbox."
  use Phoenix.Component
  import Responder.ControlPlane.Components

  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:filter_draft, fn -> RequestFilters.draft(assigns.params) end)
      |> assign_new(:filter_values, fn -> [] end)

    assigns =
      assign(
        assigns,
        :show_context,
        assigns.schedules != [] or worker_attention?(assigns.overview)
      )

    ~H"""
    <div class={"activity-layout #{if @show_context, do: "with-context"}"}>
      <section class="activity-primary">
        <div class="page-intro">
          <div>
            <h1>Requests</h1><p>Inspect incoming messages, running work, and delivered answers.</p>
          </div>
          <a :if={@activity.total > 0} class="ui-button secondary" href="/lab/new"><.icon name={:plus} />Test a message</a>
        </div>
        <div class="activity-pulse" aria-label="Current workload">
          <span><i class="pulse-dot"></i><b data-active-count>{Map.get(@overview.counts, :active, 0)}</b>
          active</span>
          <span><b>{Map.get(@overview.counts, :waiting, 0)}</b> waiting</span>
          <a href="/failures"><b>{Map.get(@overview.counts, :blocked, 0)}</b>
          blocked <.icon name={:arrow} /></a>
          <a class="pulse-usage" href="/usage">Usage & cost <.icon name={:arrow} /></a>
        </div>
        <section class="activity-inbox" aria-label="Requests">
          <div class="inbox-toolbar">
            <nav class="ui-tabs" aria-label="Activity status">
              <.link
                :for={
                  {key, name} <- [
                    {"all", "All requests"},
                    {"attention", "Needs you"},
                    {"running", "In progress"},
                    {"done", "Finished"}
                  ]
                }
                patch={filter_path(@path, @params, key)}
                aria-current={if (@params["filter"] || "all") == key, do: "page"}
              >{name}</.link>
            </nav>
            <span class="inbox-total">{@activity.total} requests</span>
          </div>
          <form
            id="activity-filters"
            class="inbox-search"
            phx-change="search-activity"
            phx-submit="search-activity"
          >
            <div class="filter-field filter-search">
              <label for="activity-search">Search</label>
              <input
                id="activity-search"
                name="q"
                type="search"
                value={@params["q"] || ""}
                phx-debounce="300"
                maxlength="200"
                placeholder="Search requests or repositories…"
                autocomplete="off"
              />
            </div>
            <div class="filter-field">
              <label for="activity-mode">Work included</label><select
                id="activity-mode"
                name="mode"
              ><option value="live" selected={@activity.mode == "live"}>Live work</option><option
                value="shadow"
                selected={@activity.mode == "shadow"}
              >
                Evaluations
              </option><option value="all" selected={@activity.mode == "all"}>
                All work
              </option></select>
            </div>
          </form>
          <RequestFilters.render
            draft={@filter_draft}
            values={@filter_values}
            params={@params}
            path={@path}
          />
          <button :if={@new_items > 0} class="new-activity" phx-click="show-new">{@new_items} new or reordered requests · Show latest
          <.icon name={:arrow} /></button>
          <div :if={@activity.total == 0} class="activity-empty">
            <h2>
              {if filtered?(@params), do: "No matching requests", else: "No requests yet"}
            </h2>
            <p>
              {if filtered?(@params),
                do: "Try another phrase or view all activity. Your filters only change this view.",
                else:
                  "Messages from connected platforms and the Conversation Lab appear here with their execution history."}
            </p>
            <.link :if={filtered?(@params)} class="ui-button secondary" patch={@path}>Clear filters</.link>
            <a :if={!filtered?(@params)} class="ui-button primary" href="/lab/new">Test a message
            <.icon name={:arrow} /></a>
          </div>
          <div id="activity-stream" phx-update="stream" class="activity-list">
            <article :for={{dom_id, item} <- @stream} id={dom_id} class="activity-row">
              <span class={"source-glyph source-#{item.kind}"} aria-hidden="true"><.icon name={
                if item.source == "Conversation Lab", do: :chat, else: :activity
              } /></span>
              <div class="activity-row-copy">
                <.link navigate={item.href} class="activity-title">{title(item)}</.link><div class="activity-meta">
                  <span>{item.source}</span><span :if={item.repository}>{item.repository}</span><span :if={
                    item.target
                  }>{item.target}</span><span
                    :if={item.source == "Slack" && item[:conversation]}
                    title={item[:conversation]}
                  >{SlackNames.destination(item.conversation)}</span><time title={
                    timestamp(item.updated_at)
                  }>{timestamp(item.updated_at)}</time>
                </div>
              </div>
              <div class="activity-row-status">
                <.status state={item.state} /><span :if={item.bucket != "done"} class="row-elapsed">{age(
                  item.started_at,
                  @now
                )} since received</span>
              </div>
              <.link navigate={item.href} class="row-open" aria-label={"Inspect #{item.title}"}><.icon name={
                :chevron
              } /></.link>
            </article>
          </div>
          <div :if={@activity.pages > 1} class="ui-pagination">
            <span>Page {@activity.page} of {@activity.pages}</span><.link
              :if={@activity.page > 1}
              patch={page_path(@path, @params, @activity.page - 1)}
            >Previous</.link><.link
              :if={@activity.page < @activity.pages}
              patch={page_path(@path, @params, @activity.page + 1)}
            >Next <.icon name={:arrow} /></.link>
          </div>
        </section>
      </section>
      <aside :if={@show_context} class="activity-rail" aria-label="Execution context">
        <section :if={@schedules != []} class="rail-section">
          <div class="rail-heading">
            <h2>Coming up</h2><a href="/schedules" aria-label="All schedules"><.icon name={:arrow} /></a>
          </div>
          <a
            :for={schedule <- @schedules}
            class="rail-schedule"
            href={"/schedules/#{URI.encode_www_form(schedule.ref)}"}
          ><span>{timestamp(schedule.next_occurrence_at)}</span><strong>{schedule.title}</strong><small>{schedule.timezone}</small></a>
        </section>
        <section :if={worker_attention?(@overview)} class="rail-section rail-runtime">
          <div class="rail-heading">
            <h2>Worker attention</h2><a href="/configuration">Inspect configuration</a>
          </div>
          <p :if={get_in(@overview, [:fleet, :unavailable])} class="runtime-problem">
            Worker status is unavailable. Check configuration before starting work.
          </p>
          <p :if={!get_in(@overview, [:fleet, :unavailable])} class="runtime-problem">
            No eligible workers. Requests need a connected worker before they can run.
          </p>
          <dl>
            <dt>Last recorded workers</dt><dd>
              {worker_label(@overview)}
            </dd>
          </dl>
          <a class="runtime-link" href="/workspaces">Inspect execution workspaces
          <.icon name={:arrow} /></a>
        </section>
      </aside>
    </div>
    """
  end

  defp filter_path(path, params, filter),
    do:
      path <>
        "?" <>
        URI.encode_query(
          Map.merge(
            Map.take(
              UsageProjection.link_params(params),
              ~w(q mode target repository state conversation thread transport) ++
                UsageProjection.filter_keys()
            ),
            %{"filter" => filter}
          )
        )

  defp page_path(path, params, page),
    do:
      path <>
        "?" <>
        URI.encode_query(
          Map.put(
            Map.take(
              UsageProjection.link_params(params),
              ~w(q mode filter target repository state conversation thread transport) ++
                UsageProjection.filter_keys()
            ),
            "page",
            page
          )
        )

  defp filtered?(params),
    do:
      Enum.any?(
        ~w(q target repository state conversation thread transport),
        &(params[&1] not in [nil, ""])
      ) or
        params["filter"] not in [nil, "all"] or UsageProjection.filtered?(params)

  defp worker_attention?(%{fleet: %{unavailable: true}}), do: true
  defp worker_attention?(%{fleet: %{required: true, eligible_workers: 0}}), do: true
  defp worker_attention?(_), do: false

  defp worker_label(%{fleet: %{eligible_workers: count}}), do: "#{count} eligible"
  defp worker_label(_), do: "Not observed"

  defp title(%{source: "Slack"} = item) do
    workspace = SlackNames.workspace_from_destination(item[:conversation])
    item.title |> SlackMarkdown.mentions(workspace) |> Phoenix.HTML.raw()
  end

  defp title(item), do: item.title
end
