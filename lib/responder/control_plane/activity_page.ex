defmodule Responder.ControlPlane.ActivityPage do
  @moduledoc "The conversation-first activity inbox."
  use Phoenix.Component
  import Responder.ControlPlane.Components

  def render(assigns) do
    ~H"""
    <div class="activity-layout">
      <section class="activity-primary">
        <div class="page-intro">
          <div>
            <p class="ui-eyebrow">WORKSPACE / ACTIVITY</p><h1>
              Your activity<span class="title-period">.</span>
            </h1><p>Every request. Its progress. The full story behind the answer.</p>
          </div>
          <a class="ui-button primary" href="/lab/new"><.icon name={:plus} />New conversation</a>
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
                    {"all", "All activity"},
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
            <.icon name={:search} /><label class="sr-only" for="activity-search">Search requests or repositories</label>
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
            <label class="sr-only" for="activity-mode">Execution mode</label><select
              id="activity-mode"
              name="mode"
            ><option value="live" selected={@activity.mode == "live"}>Live work</option><option
              value="shadow"
              selected={@activity.mode == "shadow"}
            >
              Shadow runs
            </option><option value="all" selected={@activity.mode == "all"}>
              All execution modes
            </option></select>
          </form>
          <button :if={@new_items > 0} class="new-activity" phx-click="show-new">{@new_items} new or reordered requests · Show latest
          <.icon name={:arrow} /></button>
          <div :if={@activity.total == 0} class="activity-empty">
            <div class="empty-orbit" aria-hidden="true">
              <span></span><.icon name={:chat} /><span></span>
            </div>
            <h2>
              {if filtered?(@params), do: "No matching requests", else: "Start with a conversation"}
            </h2>
            <p>
              {if filtered?(@params),
                do: "Try another phrase or view all activity. Your filters only change this view.",
                else:
                  "Send a message in the Lab to see Responder think, use its tools, and reply. No Slack noise required."}
            </p>
            <.link :if={filtered?(@params)} class="ui-button secondary" patch={@path}>Clear filters</.link>
            <a :if={!filtered?(@params)} class="ui-button primary" href="/lab/new">Open Conversation Lab
            <.icon name={:arrow} /></a>
            <div :if={!filtered?(@params)} class="empty-capabilities">
              <span><.icon name={:check} />Configured models & tools</span><span><.icon name={:check} />Durable conversation history</span>
            </div>
          </div>
          <div id="activity-stream" phx-update="stream" class="activity-list">
            <article :for={{dom_id, item} <- @stream} id={dom_id} class="activity-row">
              <span class={"source-glyph source-#{item.kind}"} aria-hidden="true"><.icon name={
                if item.source == "Conversation Lab", do: :chat, else: :activity
              } /></span>
              <div class="activity-row-copy">
                <.link navigate={item.href} class="activity-title">{item.title}</.link><div class="activity-meta">
                  <span>{item.source}</span><span :if={item.repository}>{item.repository}</span><span :if={
                    item.target
                  }>{item.target}</span><time title={timestamp(item.updated_at)}>{timestamp(
                    item.updated_at
                  )}</time>
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
        <div class="activity-footnote">
          <.icon name={:clock} /><span>Updates follow committed state. Open any request to inspect the context sent to the model.</span>
        </div>
      </section>
      <aside class="activity-rail" aria-label="Workspace context">
        <section class="rail-section">
          <div class="rail-heading">
            <h2>Coming up</h2><a href="/schedules" aria-label="All schedules"><.icon name={:arrow} /></a>
          </div>
          <div :if={@schedules == []} class="rail-empty">
            <.icon name={:clock} /><h3>No scheduled work</h3><p>
              Recurring tasks and reminders will appear here.
            </p><a href="/schedules">View schedules <.icon name={:arrow} /></a>
          </div>
          <a
            :for={schedule <- @schedules}
            class="rail-schedule"
            href={"/schedules/#{URI.encode_www_form(schedule.ref)}"}
          ><span>{timestamp(schedule.next_occurrence_at)}</span><strong>{schedule.title}</strong><small>{schedule.timezone}</small></a>
        </section>
        <section class="rail-section">
          <div class="rail-heading">
            <h2>Test your responder</h2><span class="ui-label">LABS</span>
          </div>
          <a class="rail-link" href="/lab"><.icon name={:chat} /><div>
            <strong>Conversation Lab</strong><span>Talk to the model. Inspect every step.</span>
          </div><.icon name={:chevron} /></a>
          <a class="rail-link" href="/card-lab"><.icon name={:cards} /><div>
            <strong>Slack Card Lab</strong><span>Every card, state, and transition.</span>
          </div><.icon name={:chevron} /></a>
        </section>
        <section class="rail-section rail-runtime">
          <div class="rail-heading">
            <h2>Runtime</h2><a href="/configuration">Inspect</a>
          </div>
          <p :if={get_in(@overview, [:fleet, :unavailable])} class="runtime-problem">
            Worker status is unavailable. Check configuration before starting work.
          </p>
          <dl>
            <dt>State</dt><dd>PostgreSQL</dd><dt>Access</dt><dd>Local operator</dd><dt>Workers</dt><dd>
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
          Map.merge(Map.take(params, ~w(q mode target repository state)), %{"filter" => filter})
        )

  defp page_path(path, params, page),
    do:
      path <>
        "?" <>
        URI.encode_query(
          Map.put(Map.take(params, ~w(q mode filter target repository state)), "page", page)
        )

  defp filtered?(params),
    do:
      Enum.any?(~w(q target repository state), &(params[&1] not in [nil, ""])) or
        params["filter"] not in [nil, "all"]

  defp worker_label(%{fleet: %{eligible_workers: count}}), do: "#{count} eligible"
  defp worker_label(%{fleet: %{required: false}}), do: "Local execution"
  defp worker_label(_), do: "Not observed"
end
