defmodule Ryker.ControlPlane.ActivityPage do
  @moduledoc """
  Activity (`/` and `/activity`): every message Ryker received and the work
  it started, newest first, in the page language every list shares — the
  counts it leads with, one toolbar row (search, the work included, filters,
  the four views and the total), then one row per request that opens its
  timeline from anywhere on the row.

  The rows are a LiveView stream: a refresh never moves a row under the
  reader; newer rows wait behind one button. A worker problem and the
  scheduled runs coming up are sections under the list, and a worker problem
  is also a warning count at the top, so it is seen without scrolling.
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components,
    only: [icon: 1, live_filter_toolbar: 1, page_header: 1, pager: 1]

  alias Ryker.ControlPlane.{
    Components,
    Kit,
    RequestFilters,
    SchedulesPage,
    SlackMarkdown,
    SlackNames,
    UsageProjection
  }

  @views [
    {"all", "All"},
    {"attention", "Needs you"},
    {"running", "In progress"},
    {"done", "Finished"}
  ]

  def render(assigns) do
    assigns =
      assigns
      |> assign(:activity, Map.put_new(assigns.activity, :searchable, assigns.activity.total > 0))
      |> assign_new(:filter_menu, fn -> nil end)
      |> assign_new(:filter_values, fn -> [] end)

    assigns =
      assign(assigns,
        workers: workers(assigns.overview),
        counts: counts(assigns.overview, assigns.path),
        filtered: filtered?(assigns.params)
      )

    ~H"""
    <div class="secondary-page activity-page">
      <.page_header
        title="Activity"
        description="Inspect incoming messages, running work, and delivered answers."
      >
        <:action :if={@activity.searchable}>
          <a class="ui-button secondary" href="/conversations"><.icon name={:plus} />New conversation</a>
        </:action>
      </.page_header>
      <Kit.counts label="Current workload" items={@counts} patch />
      <Kit.toolbar id="activity-toolbar" count={total(@activity.total)}>
        <.live_filter_toolbar
          id="activity-filters"
          label="Filter activity"
          placeholder="Search activity or repositories…"
          query={@params["q"] || ""}
          disabled={!@activity.searchable}
          event="search-activity"
          primary={
            %{
              id: "activity-mode",
              name: "mode",
              label: "Work included",
              value: @activity.mode,
              options: [{"live", "Live work"}, {"shadow", "Evaluations"}, {"all", "All work"}]
            }
          }
        >
          <RequestFilters.render
            values={@filter_values}
            params={@params}
            path={@path}
            menu={@filter_menu}
            disabled={!@activity.searchable}
          />
        </.live_filter_toolbar>
        <Kit.segmented label="Which requests" options={views(@path, @params)} patch />
      </Kit.toolbar>
      <button :if={@new_items > 0} class="new-activity" phx-click="show-new">
        {@new_items} new or reordered items · Show latest <.icon name={:arrow} />
      </button>
      <Kit.empty
        :if={@activity.total == 0}
        title={if @filtered, do: "No matching activity", else: "No activity yet"}
        text={
          if @filtered,
            do: "Try another phrase or view all activity. Your filters only change this view.",
            else:
              "When someone messages Ryker in Slack, GitHub or a direct conversation, it appears here with everything Ryker did about it."
        }
      >
        <.link :if={@filtered} class="ui-button secondary" patch={@path}>Clear filters</.link>
        <a :if={!@filtered} class="ui-button primary" href="/conversations">New conversation</a>
      </Kit.empty>
      <Kit.entity_list id="activity-stream" label="Activity" phx-update="stream">
        <Kit.entity_row
          :for={{dom_id, item} <- @stream}
          id={dom_id}
          name={title(item)}
          href={item.href}
          navigate
          link_row
          icon={source_icon(item)}
          icon_tone={source_tone(item)}
          group={item[:group]}
          state={state(item.state)}
          at={at(item, @now)}
          at_time={item.updated_at}
          meta={meta(item)}
        />
      </Kit.entity_list>
      <.pager
        page={@activity.page}
        pages={@activity.pages}
        path={&page_path(@path, @params, &1)}
        label="Activity pages"
        earlier="Previous"
        later="Next"
      />
      <section :if={@workers} id="workers" class="activity-section" aria-labelledby="workers-title">
        <Kit.section_head
          id="workers-title"
          title="Workers"
          lede="Every request runs on a connected worker."
        />
        <Kit.entity_list label="Workers">
          <Kit.entity_row
            id="worker-attention"
            name={@workers.name}
            state={{:warn, "Needs attention"}}
            text={@workers.text}
            meta={[@workers.seen]}
          >
            <:actions>
              <a class="ui-button secondary" href="/settings/advanced">Worker settings</a>
              <a class="ui-button secondary" href="/working-copies">Working copies</a>
            </:actions>
          </Kit.entity_row>
        </Kit.entity_list>
      </section>
      <section
        :if={@schedules != []}
        id="coming-up"
        class="activity-section"
        aria-labelledby="coming-up-title"
      >
        <Kit.section_head
          id="coming-up-title"
          title="Coming up"
          lede="The scheduled runs due next."
        >
          <:actions><a href="/schedules">All schedules</a></:actions>
        </Kit.section_head>
        <Kit.entity_list label="Coming up">
          <Kit.entity_row
            :for={schedule <- @schedules}
            id={"coming-up-" <> schedule.ref}
            name={schedule.title}
            href={"/schedules/" <> URI.encode_www_form(schedule.ref)}
            link_row
            meta={SchedulesPage.row_facts(schedule)}
          />
        </Kit.entity_list>
      </section>
    </div>
    """
  end

  @doc """
  A request's state as a dot and a word. Anything that needs a person is the
  warn tone, anything Ryker is doing now is busy, and finished work is quiet.
  """
  @spec state(String.t() | atom()) :: {atom(), String.t()}
  def state(state) when is_atom(state) and not is_nil(state), do: state(Atom.to_string(state))
  def state("waiting_for_event"), do: {:busy, Components.label("waiting_for_event")}
  def state("superseded"), do: {:off, "Replaced by an edit"}
  def state("start_episode"), do: {:busy, "Starting"}
  def state("continue_episode"), do: {:off, "Added to earlier work"}
  def state("decided"), do: {:off, "Handled"}

  def state(state) do
    tone =
      case Components.tone(state) do
        "attention" -> :warn
        "active" -> :busy
        _finished -> :off
      end

    {tone, Components.label(state)}
  end

  # The workload the page leads with; each count opens the view that lists
  # it, and a worker problem joins them as a warning that leads to its section.
  defp counts(overview, path) do
    counts = overview.counts
    blocked = Map.get(counts, :blocked, 0)

    [
      %{value: Map.get(counts, :active, 0), label: "active", href: view_path(path, "running")},
      %{
        value: Map.get(counts, :waiting, 0),
        label: "waiting",
        href: view_path(path, "attention")
      },
      %{
        value: blocked,
        label: "blocked",
        tone: if(blocked > 0, do: :warn),
        href: view_path(path, "attention")
      }
    ] ++ worker_count(overview)
  end

  defp worker_count(%{fleet: %{unavailable: true}}),
    do: [%{value: "Unknown", label: "worker status", tone: :warn, href: "#workers"}]

  defp worker_count(%{fleet: %{required: true, eligible_workers: 0}}),
    do: [%{value: 0, label: "workers available", tone: :warn, href: "#workers"}]

  defp worker_count(_overview), do: []

  defp view_path(path, view), do: path <> "?" <> URI.encode_query(%{"filter" => view})

  defp workers(%{fleet: %{unavailable: true} = fleet}) do
    %{
      name: "Worker status is unknown",
      text:
        "Ryker could not read the workers’ state. Check the worker settings before starting work.",
      seen: seen(fleet)
    }
  end

  defp workers(%{fleet: %{required: true, eligible_workers: 0} = fleet}) do
    %{
      name: "No worker can take work",
      text: "Requests wait until a connected worker can run them.",
      seen: seen(fleet)
    }
  end

  defp workers(_overview), do: nil

  defp seen(%{eligible_workers: 1}), do: "last check: 1 worker available"

  defp seen(%{eligible_workers: count}) when is_integer(count),
    do: "last check: #{count} workers available"

  defp seen(_fleet), do: "no worker seen yet"

  defp views(path, params) do
    current =
      if params["filter"] in Enum.map(@views, &elem(&1, 0)), do: params["filter"], else: "all"

    for {key, name} <- @views, do: {name, filter_path(path, params, key), current == key}
  end

  defp total(1), do: "1 item"
  defp total(count), do: "#{count} items"

  # Where the request came from and its repository; when is the row's edge.
  defp meta(item), do: [{:strong, where(item)}, item.repository]

  # Where a request came from is the one thing its tile says.
  defp source_icon(%{source: "Slack"}), do: :hash
  defp source_icon(%{source: "GitHub"}), do: :code
  defp source_icon(%{source: "Direct conversation"}), do: :chat
  defp source_icon(_item), do: :plug

  defp source_tone(%{source: "Slack"}), do: :info
  defp source_tone(%{source: "Direct conversation"}), do: :accent
  defp source_tone(_item), do: :off

  # Under its day's heading a row says only the clock time. A row that
  # changed since the list was drawn stays under its old day until the reader
  # shows the latest, so it names its new day too.
  defp at(%{updated_at: nil}, _now), do: nil

  defp at(%{updated_at: updated_at} = item, now) do
    day = updated_at |> utc() |> DateTime.to_date()

    case Map.get(item, :day) do
      section when section in [nil, day] ->
        Kit.clock(updated_at)

      _other_day ->
        Kit.day_label(day, DateTime.to_date(now)) <> " " <> Kit.clock(updated_at)
    end
  end

  @doc """
  Rows as the list first draws them: each carries the day it is listed
  under, and the first of each day that day's heading.
  """
  @spec with_days([map()], DateTime.t()) :: [map()]
  def with_days(items, now) do
    groups = Kit.day_groups(items, & &1.updated_at, now)

    items
    |> Enum.zip(groups)
    |> Enum.map(fn {item, group} ->
      Map.merge(item, %{group: group, day: item.updated_at && day(item.updated_at)})
    end)
  end

  @doc """
  Rows still shown after a refresh, in the order they are shown: each keeps
  the day it was listed under (`days`, by row), and the first shown row of
  each day carries its heading, so a removed row never takes it away.
  """
  @spec kept_days([{String.t(), map()}], %{String.t() => Date.t() | nil}, DateTime.t()) :: [
          map()
        ]
  def kept_days(rows, days, now) do
    today = DateTime.to_date(now)

    rows
    |> Enum.map_reduce(nil, fn {dom_id, item}, previous ->
      day = Map.get(days, dom_id)
      group = if day && day != previous, do: Kit.day_label(day, today)
      {Map.merge(item, %{group: group, day: day}), day || previous}
    end)
    |> elem(0)
  end

  defp day(at), do: at |> utc() |> DateTime.to_date()

  defp utc(%DateTime{} = at), do: DateTime.shift_zone!(at, "Etc/UTC")
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp where(%{source: "Slack", conversation: conversation}) when is_binary(conversation),
    do: SlackNames.destination(conversation)

  defp where(item), do: item.source

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

  defp title(%{source: "Slack"} = item) do
    workspace = SlackNames.workspace_from_destination(item[:conversation])
    item.title |> SlackMarkdown.mentions(workspace) |> Phoenix.HTML.raw()
  end

  defp title(item), do: item.title
end
