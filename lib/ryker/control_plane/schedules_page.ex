defmodule Ryker.ControlPlane.SchedulesPage do
  @moduledoc """
  Automations › Schedules: the tasks Ryker runs at a set time, once or on
  repeat, and one schedule's own page with its runs.

  Rows follow the Kit: the title and its state, what the schedule asks for,
  then one line of facts in words — how often in the schedule's own time
  zone, where results go, when it runs next. Times arrive from the projection
  already converted to that zone, because "every day at 09:00 Berlin time"
  beside a next run of "07:00 UTC" reads as a contradiction. References,
  revisions and diagnostics stay in one closed Details disclosure.

  Some Kit attributes receive small rendered fragments rather than plain
  strings — a channel name in bold, a time with its exact UTC value on hover,
  a link inside a fact. HEEx renders a fragment wherever it renders text.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, Kit, ShortTime}
  alias Ryker.Schedules.ScheduleCadence
  alias Ryker.Slack.Names

  @list_limit 100
  @runs_limit 200
  @changeable [:active, :paused]

  @doc "The one sentence under the page title."
  @spec description() :: String.t()
  def description, do: "Tasks Ryker runs at a set time, once or on repeat."

  @doc """
  The list's query: the search, and whether it shows current schedules
  (running or paused) or past ones (done, expired or deleted).
  """
  @spec params(map()) :: %{String.t() => String.t()}
  def params(params) do
    query = if is_binary(params["q"]), do: String.slice(params["q"], 0, 200), else: ""
    %{"q" => query, "view" => if(params["view"] == "past", do: "past", else: "current")}
  end

  @doc "The Schedules list: the toolbar and the rows. How to add one is the page's help."
  @spec list([map()], map()) :: iodata()
  def list(items, params) do
    %{
      __changed__: nil,
      items: Enum.take(items, @list_limit),
      full: length(items) >= @list_limit,
      query: params["q"] || "",
      view: params["view"] || "current"
    }
    |> list_view()
    |> Safe.to_iodata()
  end

  defp list_view(assigns) do
    ~H"""
    <div class="schedules-view">
      <Kit.toolbar>
        <Components.filter_toolbar
          id="operator-search"
          path="/schedules"
          label="Search schedules"
          placeholder="Search schedules"
          query={@query}
          filtered={@query != ""}
          hidden={if @view == "past", do: [{"view", "past"}], else: []}
          clear={view_path("/schedules", "", @view)}
        />
        <Kit.segmented label="Which schedules" options={segments("/schedules", @query, @view)} />
      </Kit.toolbar>
      <Kit.entity_list :if={@items != []} label="Schedules">
        <Kit.entity_row
          :for={item <- @items}
          id={"schedule-" <> item.ref}
          icon={:clock}
          name={item.title}
          href={schedule_path(item.ref)}
          state={state(item.status)}
          text={first_line(item.task)}
          meta={row_facts(item)}
        >
          <:actions :if={item.status in [:active, :paused, :completed]}>
            <.controls schedule={item} />
          </:actions>
        </Kit.entity_row>
      </Kit.entity_list>
      <p :if={@full} class="schedule-note">
        Showing the first 100 schedules. Search to narrow the list.
      </p>
      <.list_empty :if={@items == []} query={@query} view={@view} />
    </div>
    """
  end

  attr(:query, :string, required: true)
  attr(:view, :string, required: true)

  defp list_empty(%{query: query} = assigns) when query != "" do
    ~H"""
    <Kit.empty
      title={"No schedules match “#{@query}”"}
      text={"Try other words, or look under #{if @view == "past", do: "Current", else: "Past"}."}
    />
    """
  end

  defp list_empty(%{view: "past"} = assigns) do
    ~H"""
    <Kit.empty
      title="No past schedules"
      text="Schedules move here when they finish, expire or are deleted."
    />
    """
  end

  defp list_empty(assigns) do
    ~H"""
    <Kit.empty
      title="Nothing is scheduled"
      text="A schedule appears here once you ask Ryker to run something at a set time and confirm it."
    />
    """
  end

  @doc """
  One schedule's facts as its row shows them: how often and where results go,
  when it runs next and stops in its own time zone, its repository and any
  failed starts. Activity's "Coming up" rows use the same words.
  """
  @spec row_facts(map()) :: list()
  def row_facts(item) do
    changeable? = item.status in @changeable

    [
      how_often(item),
      place(item),
      if(item.status == :active and item.next_local,
        do:
          moment(next_lead(item), item.next_local, item.now_local, item.next_occurrence_at, :time,
            zone: item.timezone
          )
      ),
      if(changeable? and item.expires_local,
        do: moment("stops ", item.expires_local, item.now_local, item.expires_at, :date, [])
      ),
      if(item.repository, do: labelled("repository ", item.repository)),
      if(changeable? and item.failures > 0, do: warning(failed_starts(item.failures)))
    ]
  end

  @doc "The actions opposite one schedule's title, or nil once it can no longer change."
  @spec actions(map()) :: binary() | nil
  def actions(%{status: status} = schedule) when status in [:active, :paused, :completed] do
    %{__changed__: nil, schedule: schedule}
    |> controls()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  def actions(_schedule), do: nil

  attr(:schedule, :map, required: true)

  # Run now, then Pause or Resume; Delete sits behind "⋯" because it cannot
  # be undone. Each opens the existing confirmation page first.
  defp controls(assigns) do
    ~H"""
    <Components.action_button path={action_path(@schedule.ref, "run-now")} label="Run now" />
    <Components.action_button
      :if={@schedule.status == :active}
      path={action_path(@schedule.ref, "paused")}
      label="Pause"
    />
    <Components.action_button
      :if={@schedule.status == :paused}
      path={action_path(@schedule.ref, "active")}
      label="Resume"
    />
    <details :if={@schedule.status in [:active, :paused]} class="schedule-menu">
      <summary class="ui-button secondary" phx-no-format><span aria-hidden="true">⋯</span><span class="sr-only">More actions for {@schedule.title}</span></summary>
      <div class="schedule-menu-items">
        <Components.action_button
          path={action_path(@schedule.ref, "deleted")}
          label="Delete"
          tone={:danger}
        />
      </div>
    </details>
    """
  end

  @doc "One schedule's page body: its state, its facts, what it asks for, its runs, Details."
  @spec detail(%{schedule: map(), occurrences: [map()]}, DateTime.t()) :: iodata()
  def detail(%{schedule: schedule, occurrences: runs}, now \\ DateTime.utc_now()) do
    {tone, word} = state(schedule.status)

    %{
      __changed__: nil,
      schedule: schedule,
      tone: tone,
      word: word,
      facts: detail_facts(schedule),
      runs: Enum.take(runs, @runs_limit),
      full: length(runs) >= @runs_limit,
      now: now
    }
    |> detail_view()
    |> Safe.to_iodata()
  end

  defp detail_view(assigns) do
    ~H"""
    <div class="schedule-view">
      <Kit.status_line state={{@tone, @word}}>
        <span
          :if={@schedule.status in [:active, :paused] and @schedule.failure_count > 0}
          class="schedule-warning"
        >{failed_starts(@schedule.failure_count)}</span>
      </Kit.status_line>
      <Kit.facts facts={@facts} />
      <Kit.section_head title="What it asks for" />
      <p class="schedule-task">{@schedule.task}</p>
      <Kit.section_head title="Runs" lede={runs_lede(@schedule)} />
      <div class="schedule-runs">
        <Kit.entity_list :if={@runs != []} label="Runs">
          <Kit.entity_row
            :for={run <- @runs}
            name={due(run, @schedule)}
            href={run.episode_ref && timeline_path(run.episode_ref)}
            state={run_state(run)}
            meta={run_facts(run, @now)}
          />
        </Kit.entity_list>
        <Kit.empty :if={@runs == []} title="No runs yet" text={no_runs(@schedule)} />
        <p :if={@full} class="schedule-note">Showing the 200 most recent runs.</p>
      </div>
      <Components.disclosure id="schedule-details" label="Details" class="schedule-details">
        <Components.fact_list facts={support_facts(@schedule)} />
      </Components.disclosure>
    </div>
    """
  end

  # Run times are the schedule's own clock; the list names the zone once
  # rather than on every row.
  defp runs_lede(schedule),
    do:
      "Each run starts its own request. Newest first. Times are " <>
        ScheduleCadence.zone_name(schedule.timezone) <> "."

  defp detail_facts(schedule) do
    changeable? = schedule.status in @changeable

    [
      {"How often", how_often(schedule)},
      {"Where results go", destination(schedule)},
      {"Repository", schedule.repository},
      {"What it may do", authority(schedule.authority)},
      {"Next run", if(changeable?, do: next_run(schedule))},
      {"Stops", if(changeable?, do: stops(schedule))},
      {"Started from", started_from(schedule)}
    ]
    |> Enum.reject(fn {_label, value} -> value in [nil, ""] end)
  end

  defp next_run(%{status: :paused}), do: "None while it is paused"

  defp next_run(%{next_local: %NaiveDateTime{} = local} = schedule),
    do:
      moment(nil, local, schedule.now_local, schedule.next_occurrence_at, :time,
        zone: schedule.timezone
      )

  defp next_run(_schedule), do: nil

  defp stops(%{expires_local: %NaiveDateTime{} = local} = schedule),
    do:
      moment(nil, local, schedule.now_local, schedule.expires_at, :time, zone: schedule.timezone)

  defp stops(_schedule), do: "Never"

  defp started_from(%{source_request: %{title: title, href: href}}),
    do: anchor(%{href: href, text: title})

  defp started_from(%{source_episode_ref: ref}) when is_binary(ref),
    do: anchor(%{href: timeline_path(ref), text: "The conversation where it was set up"})

  defp started_from(_schedule), do: nil

  defp no_runs(%{status: :active, next_local: %NaiveDateTime{} = local} = schedule),
    do: "The first run is due #{short(local, schedule.now_local)}."

  defp no_runs(_schedule), do: "It has not run yet."

  defp support_facts(schedule) do
    [
      %{label: "Schedule ID", value: schedule.ref, identifier: true},
      %{label: "Revision", value: to_string(schedule.revision)},
      %{label: "Time zone", value: schedule.timezone},
      schedule[:confirmed_at] && %{label: "Set up", value: exact(schedule.confirmed_at)},
      schedule[:source_episode_ref] &&
        %{label: "Started from request", value: schedule.source_episode_ref, identifier: true},
      schedule[:last_error] &&
        %{label: "Last problem", value: schedule.last_error, identifier: true}
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  # A run is one request: its state comes from that request and the turn that
  # ran it, never from the dispatcher's bookkeeping.
  defp run_state(%{status: :missed}), do: {:warn, "Missed"}
  defp run_state(%{episode_state: :cancelled}), do: {:off, "Stopped"}
  defp run_state(%{episode_state: :complete}), do: {:off, "Completed"}
  defp run_state(%{turn_status: :blocked}), do: {:bad, "Failed"}
  defp run_state(%{episode_state: :waiting_for_input}), do: {:warn, "Needs an answer"}
  defp run_state(%{episode_state: :waiting_for_event}), do: {:busy, "Waiting"}
  defp run_state(%{episode_state: :working}), do: {:busy, "Running"}
  defp run_state(_run), do: {:off, "Started"}

  defp run_facts(run, now) do
    [
      if(Map.get(run, :trigger) == :manual, do: "Run by hand", else: "Scheduled"),
      run_time(run, now),
      attempts(Map.get(run, :work_attempt_count)),
      run_problem(run)
    ]
  end

  defp run_time(%{status: :missed}, _now), do: nil

  defp run_time(run, now) do
    started = Map.get(run, :started_at)
    finished = Map.get(run, :delivered_at) || Map.get(run, :finished_at)

    cond do
      is_nil(started) ->
        nil

      finished ->
        "took " <> elapsed(DateTime.diff(finished, started))

      run_state(run) == {:busy, "Running"} ->
        started(DateTime.diff(now, started))

      true ->
        nil
    end
  end

  defp started(seconds) when seconds < 60, do: "started just now"
  defp started(seconds), do: "started #{elapsed(seconds)} ago"

  defp attempts(count) when is_integer(count) and count > 1, do: "#{count} attempts"
  defp attempts(_count), do: nil

  defp run_problem(%{status: :missed, missed_reason: "outside_misfire_grace"}),
    do: "could not start on time"

  defp run_problem(%{status: :missed}), do: "did not start"

  defp run_problem(run) do
    case run_state(run) do
      {:bad, _word} -> Map.get(run, :failure_cause) || failure_words(Map.get(run, :failure_code))
      _other -> nil
    end
  end

  defp failure_words(code) when code in ~w(coop_unavailable coop_transport_error),
    do: "could not reach the worker"

  defp failure_words(_code), do: "stopped before it finished"

  # How often, in the schedule's own zone, from the one wording every surface
  # shares; the projection has already converted a single run to local time.
  defp how_often(schedule) do
    ScheduleCadence.describe(schedule.recurrence, schedule.timezone,
      once_local: Map.get(schedule, :once_local),
      now_local: Map.get(schedule, :now_local)
    )
  end

  defp destination(%{destination_transport: "slack"} = schedule) do
    name = Names.destination(schedule.destination_conversation_ref)

    channel =
      case channel_path(schedule.destination_conversation_ref) do
        nil -> name
        path -> anchor(%{href: path, text: name})
      end

    if schedule.destination_thread_ref,
      do: with_suffix(%{value: channel, suffix: " · in a thread"}),
      else: channel
  end

  defp destination(%{destination_conversation_ref: "control-plane:lab:" <> id}) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> anchor(%{href: "/conversations/" <> id, text: "A direct conversation"})
      :error -> "A direct conversation"
    end
  end

  defp destination(schedule), do: Names.destination(schedule.destination_conversation_ref)

  # Where a list row's results go: "in #incidents", "in a thread in
  # #incidents", "in a direct conversation".
  defp place(%{destination_transport: "slack"} = item) do
    name = Names.destination(item.destination_conversation_ref)
    lead = if item.destination_thread_ref, do: "in a thread in ", else: "in "
    labelled(lead, name)
  end

  defp place(%{destination_conversation_ref: "control-plane:lab:" <> _id}),
    do: "in a direct conversation"

  defp place(item), do: "in " <> Names.destination(item.destination_conversation_ref)

  # Only a Slack channel has a page of its own here; a direct message has not.
  defp channel_path("slack:" <> rest) do
    case String.split(rest, ":") do
      [workspace, <<prefix, _rest::binary>> = channel] when prefix in [?C, ?G] ->
        "/channels/#{segment(workspace)}/#{segment(channel)}"

      _other ->
        nil
    end
  end

  defp channel_path(_ref), do: nil

  defp authority(:read_only), do: "Read only"
  defp authority(:repository_write), do: "Can change the repository"
  defp authority(:governed_operation), do: "Can run approved operations"

  defp state(:active), do: {:on, "On"}
  defp state(:paused), do: {:off, "Paused"}
  defp state(:completed), do: {:off, "Done"}
  defp state(:expired), do: {:off, "Expired"}
  defp state(:deleted), do: {:off, "Deleted"}

  defp failed_starts(1), do: "failed to start once"
  defp failed_starts(count), do: "failed to start #{count} times"

  defp first_line(task) when is_binary(task) do
    task
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
  end

  defp first_line(_task), do: nil

  defp due(run, schedule) do
    local = Map.get(run, :due_local) || DateTime.to_naive(run.scheduled_for)
    moment(nil, local, schedule.now_local, run.scheduled_for, :time, [])
  end

  # A time in the schedule's own zone, short in the text and exact in UTC on
  # hover: "today 09:00", "tomorrow 09:00", "25 Sep, 09:00", or just "31 Oct".
  # A clock time names its zone ("tomorrow 09:00 Berlin time"); a bare date
  # needs none.
  # A run that did not start when due is something to notice, not a run
  # coming up (manual testing, 2026-09-26: "next run 28 Aug" on 26 Sep).
  defp next_lead(%{next_local: %NaiveDateTime{} = next, now_local: %NaiveDateTime{} = now}) do
    if NaiveDateTime.compare(next, now) == :lt, do: "was due ", else: "next run "
  end

  defp next_lead(_item), do: "next run "

  defp moment(lead, local, now_local, utc, style, options) do
    text =
      case style do
        :date -> day(local, now_local)
        :time -> short(local, now_local) <> zone_suffix(Keyword.get(options, :zone))
      end

    at_time(%{lead: lead, text: text, utc: utc})
  end

  defp zone_suffix(nil), do: ""
  defp zone_suffix(timezone), do: " " <> ScheduleCadence.zone_name(timezone)

  defp short(%NaiveDateTime{} = local, %NaiveDateTime{} = now) do
    case Date.diff(NaiveDateTime.to_date(local), NaiveDateTime.to_date(now)) do
      0 -> "today " <> clock(local)
      1 -> "tomorrow " <> clock(local)
      -1 -> "yesterday " <> clock(local)
      _other -> day(local, now) <> ", " <> clock(local)
    end
  end

  defp short(local, _now), do: day(local, nil) <> ", " <> clock(local)

  defp day(%NaiveDateTime{year: year} = local, %NaiveDateTime{year: year}),
    do: Calendar.strftime(local, "%-d %b")

  defp day(local, _now), do: Calendar.strftime(local, "%-d %b %Y")

  defp clock(local), do: Calendar.strftime(local, "%H:%M")

  defp exact(%DateTime{} = utc), do: ShortTime.full(utc)
  defp exact(_value), do: nil

  defp elapsed(seconds) when seconds < 60, do: "#{max(seconds, 1)} s"
  defp elapsed(seconds) when seconds < 3_600, do: "#{div(seconds, 60)} min"

  defp elapsed(seconds) do
    hours = div(seconds, 3_600)

    case div(rem(seconds, 3_600), 60) do
      0 -> "#{hours} h"
      minutes -> "#{hours} h #{minutes} min"
    end
  end

  defp segments(path, query, view) do
    [
      {"Current", view_path(path, query, "current"), view == "current"},
      {"Past", view_path(path, query, "past"), view == "past"}
    ]
  end

  defp view_path(path, query, view) do
    [{"q", query}, {"view", if(view == "past", do: "past")}]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> case do
      [] -> path
      params -> path <> "?" <> URI.encode_query(params)
    end
  end

  defp schedule_path(ref), do: "/schedules/" <> segment(ref)
  defp timeline_path(ref), do: "/timeline/" <> segment(ref)
  defp action_path(ref, action), do: "/actions/schedule/#{segment(ref)}/#{action}"
  defp segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  # The fragments below go where the Kit expects text.

  defp at_time(%{utc: nil} = assigns), do: ~H"{@lead}{@text}"

  defp at_time(assigns) do
    ~H"""
    {@lead}<time datetime={DateTime.to_iso8601(@utc)} title={exact(@utc)}>{@text}</time>
    """
  end

  defp labelled(lead, value) do
    assigns = %{lead: lead, value: value}
    ~H"{@lead}<strong>{@value}</strong>"
  end

  defp warning(text) do
    assigns = %{text: text}
    ~H|<span class="schedule-warning">{@text}</span>|
  end

  defp anchor(assigns), do: ~H|<a href={@href}>{@text}</a>|

  defp with_suffix(assigns), do: ~H"{@value}{@suffix}"
end
