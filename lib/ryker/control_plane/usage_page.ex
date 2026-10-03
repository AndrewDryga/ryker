defmodule Ryker.ControlPlane.UsagePage do
  @moduledoc """
  Usage & cost: the period's totals, its tokens over time, where the time
  went, then where the money went, one breakdown at a time, and the rates
  that made the estimates. An open page redraws when usage is recorded or a
  price changes (`subscriptions/0`).
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.{Accounting, Settings}

  alias Ryker.ControlPlane.{
    Components,
    Kit,
    Paths,
    SettingsRows,
    UsageChart,
    UsageProjection
  }

  alias Ryker.Episodes.Words
  alias Ryker.Slack.Names
  alias Ryker.Work.ExecutionTarget

  # Every work type the projection can name; anything else is a missing identity.
  @work_kinds ~w(admission learning self_analysis repository_knowledge conversational standard deep continuation resumed task event_wait schedule publication approval)

  def work_kinds, do: @work_kinds

  @doc """
  The topics an open Usage page listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): every execution's
  usage and the prices in the settings.
  """
  def subscriptions,
    do: [
      {Accounting, :subscribe_usage, []},
      {Settings, :subscribe, []}
    ]

  def render(snapshot) do
    totals = snapshot.totals

    [
      "<div class=\"usage-page\">",
      filters(snapshot),
      "<section class=\"usage-summary\" aria-label=\"Usage summary\"><div class=\"usage-headlines\">",
      stat("Cost", money(totals), "usage-cost"),
      stat("Requests", number(value(totals, :requests))),
      stat("Executions", number(totals.attempts)),
      stat("Total tokens", compact(value(totals, :tokens))),
      "</div><div class=\"usage-token-groups\"><div class=\"usage-token-group\"><span class=\"usage-group-label\">Input</span>",
      stat("Fresh input", compact(totals.input_tokens)),
      stat("Cached input", compact(totals.cached_input_tokens)),
      "</div><div class=\"usage-token-group\"><span class=\"usage-group-label\">Output</span>",
      stat("Output", compact(totals.output_tokens)),
      stat("Reasoning", compact(totals.reasoning_tokens)),
      "</div><div class=\"usage-token-group usage-cache\">",
      stat("Cache hit rate", percent(totals.cache_hit_rate)),
      "</div></div></section>",
      "<div class=\"usage-charts\"><section class=\"usage-trend-panel\"><h2>Token usage over time</h2>",
      UsageChart.render(snapshot.days),
      "</section><section class=\"usage-timing-panel\"><h2>Where the time went</h2>",
      timing(totals),
      "</section></div>",
      breakdown(snapshot),
      methodology(snapshot),
      "</div>"
    ]
  end

  defp filters(snapshot) do
    mode = Map.get(snapshot, :mode, "live")
    by = Map.get(snapshot, :by, "work-type")

    [
      "<div class=\"usage-filters\"><nav class=\"windows\" aria-label=\"Usage window\">",
      Enum.map(~w(24h 7d 30d all), fn window ->
        filter_link([window: window, mode: mode, by: by], window, window == snapshot.window)
      end),
      "</nav><nav class=\"windows usage-scope\" aria-label=\"Execution scope\">",
      Enum.map([{"all", "All work"}, {"live", "Live work"}, {"shadow", "Evaluations"}], fn {scope,
                                                                                            label} ->
        filter_link([window: snapshot.window, mode: scope, by: by], label, scope == mode)
      end),
      "</nav></div>"
    ]
  end

  defp filter_link(params, label, selected) do
    [
      "<a href=\"",
      e(usage_path(params)),
      "\"",
      if(selected, do: " aria-current=\"page\"", else: ""),
      ">",
      e(label),
      "</a>"
    ]
  end

  # Its parameters as a keyword list, so a link reads the same on every load.
  defp usage_path(params), do: "/usage?" <> Paths.encode_query(params)

  defp stat(label, amount, class \\ "") do
    [
      "<div class=\"usage-stat ",
      class,
      "\"><span>",
      label,
      "</span><strong>",
      e(amount),
      "</strong></div>"
    ]
  end

  # -- Where the money went ----------------------------------------------------

  # Andrew, 2026-10-03, of six tables of token columns, the cost cut off at the
  # right edge: "what i am supposed to do or learn by looking at them?" One
  # table now answers one question at a time, chosen above it: what each kind
  # of work, model, channel, repository, person or account cost, most first,
  # with its share of the whole, what one request cost and how many runs
  # failed. Each name opens the requests behind it on Activity.
  @breakdowns [
    {"work-type", "Work type"},
    {"model", "Model"},
    {"channel", "Channel"},
    {"repository", "Repository"},
    {"person", "Person"},
    {"account", "Account"}
  ]

  @ledes %{
    "work-type" => "What each kind of work cost, most first.",
    "model" => "What each model cost, and how often its runs failed.",
    "channel" => "What the requests from each Slack channel cost.",
    "repository" => "What the work in each repository cost.",
    "person" => "What the requests each person made cost.",
    "account" => "What ran on each model account."
  }

  defp breakdown(snapshot) do
    by = Map.get(snapshot, :by, "work-type")
    rows = Map.get(snapshot, :rows, [])
    known = Enum.reject(rows, &missing_identity?(&1, by))
    total = snapshot.totals
    by_cost? = cost(total) > 0

    %{
      __changed__: nil,
      by: by,
      label: label(by),
      lede: Map.fetch!(@ledes, by),
      options:
        Enum.map(@breakdowns, fn {key, label} ->
          {label,
           usage_path(window: snapshot.window, mode: Map.get(snapshot, :mode, "live"), by: key),
           key == by}
        end),
      rows: known |> Enum.take(500) |> Enum.map(&line(&1, by, snapshot, total, by_cost?)),
      share: if(by_cost?, do: "Share of cost", else: "Share of tokens"),
      empty: if(known == [], do: empty(by)),
      truncated: length(rows) > 500
    }
    |> breakdown_view()
    |> Safe.to_iodata()
  end

  defp breakdown_view(assigns) do
    ~H"""
    <section id="usage-breakdown" class="usage-breakdown" aria-label="Where the money went">
      <Kit.section_head title="Where the money went" lede={@lede}>
        <:actions>
          <Kit.segmented label="Break the cost down by" options={@options} />
        </:actions>
      </Kit.section_head>
      <Kit.table
        :if={@rows != []}
        id="usage-breakdown-table"
        label={"Cost by " <> String.downcase(@label)}
        rows={@rows}
      >
        <:col :let={row} label={@label}>
          <span class="usage-name">{row.name}</span>
          <small :if={row.details != []} class="usage-details">
            <%= for {detail, index} <- Enum.with_index(row.details) do %>
              <span :if={index > 0} aria-hidden="true"> · </span>{detail}
            <% end %>
          </small>
        </:col>
        <:col :let={row} label={@share} numeric>
          <span class="usage-share">
            <svg viewBox="0 0 100 6" preserveAspectRatio="none" aria-hidden="true">
              <rect class="usage-share-track" width="100" height="6" rx="3" />
              <rect class="usage-share-fill" width={row.share_width} height="6" rx="3" />
            </svg>
            <span class="usage-share-value">{row.share}</span>
          </span>
        </:col>
        <:col :let={row} label="Cost" numeric>{row.cost}</:col>
        <:col :let={row} label="Requests" numeric>{row.requests}</:col>
        <:col :let={row} label="Per request" numeric>{row.per_request}</:col>
        <:col :let={row} label="Failed runs" numeric>{row.failed}</:col>
      </Kit.table>
      <Kit.empty
        :if={@empty}
        variant={:hint}
        icon={:usage}
        title={elem(@empty, 0)}
        text={elem(@empty, 1)}
      />
      <p :if={@truncated} class="usage-truncated">
        Showing the 500 largest. The totals above include all of it.
      </p>
    </section>
    """
  end

  # One row: its name, which opens what it stands for, the line under it, and
  # its figures.
  defp line(row, by, snapshot, total, by_cost?) do
    share =
      if by_cost?,
        do: cost(row) / cost(total),
        else: share(row, total)

    %{
      name: name(row, by, snapshot),
      details: row |> details(by) |> Enum.reject(&is_nil/1),
      share: percent(share),
      share_width: coordinate(min((share || 0) * 100, 100)),
      cost: money(row),
      requests: if(value(row, :requests) > 0, do: number(row.requests), else: "—"),
      per_request: per_request(row),
      failed: failed(row)
    }
  end

  defp label(by), do: @breakdowns |> List.keyfind(by, 0) |> elem(1)

  # What the row stands for, as a link to the requests behind it.
  defp name(row, "work-type", snapshot),
    do: kind_link(row.work_kind, kind_name(row.work_kind), %{work_kind: row.work_kind}, snapshot)

  defp name(row, "model", snapshot),
    do:
      entity_link(
        model_name(row),
        %{model: row.model, provider: row.provider, effort: Map.get(row, :effort)},
        snapshot
      )

  defp name(row, "channel", snapshot),
    do: entity_link(channel(row), %{channel: row.conversation_ref}, snapshot)

  defp name(row, "repository", snapshot),
    do:
      entity_link(
        row[:repository_name] || "No repository",
        %{repository: row.repository_ref || ""},
        snapshot
      )

  defp name(row, "person", snapshot),
    do:
      entity_link(
        user(row),
        %{actor: row.actor, actor_kind: "user", workspace: row.workspace, source: row.source},
        snapshot
      )

  defp name(row, "account", snapshot),
    do: entity_link(row.profile, %{profile: row.profile, provider: row.provider}, snapshot)

  # The quiet line under a name, one line long: how many runs it took, how
  # long one took and how many answers were sent back, what it ran on, or
  # where a person comes from.
  defp details(row, "work-type"),
    do: [runs(row), each(row), corrections(row), models(row[:models] || [])]

  defp details(row, "model"),
    do: [row.provider, runs(row), each(row), corrections(row), tokens_line(row)]

  defp details(row, "person"), do: [source(row), runs(row)]
  defp details(row, "account"), do: [row.provider, runs(row), tokens_line(row)]
  defp details(row, _by), do: [runs(row), tokens_line(row)]

  # The models a kind of work ran on, most runs first; the rest are named
  # when the pointer rests on them.
  defp models([]), do: nil
  defp models([one]), do: "on " <> model_name(one)

  defp models([one | rest] = all),
    do:
      more_mark(%{
        __changed__: nil,
        first: model_name(one),
        more: length(rest),
        all: Enum.map_join(all, ", ", &model_name/1)
      })

  defp more_mark(assigns) do
    ~H"""
    <span title={@all}>on {@first} and {@more} more</span>
    """
  end

  defp model_name(row),
    do: Enum.join(Enum.reject([row.model, Map.get(row, :effort)], &is_nil/1), "/")

  defp runs(%{attempts: 1}), do: "1 run"
  defp runs(row), do: number(row.attempts) <> " runs"

  # Answers Ryker's checks sent back to the model to fix, named the way the
  # request's timeline names them.
  defp corrections(%{corrections: 1}), do: "1 correction"

  defp corrections(%{corrections: count}) when is_integer(count) and count > 1,
    do: number(count) <> " corrections"

  defp corrections(_row), do: nil

  defp each(%{average_provider_ms: ms}) when is_integer(ms), do: elapsed(ms) <> " a run"
  defp each(_row), do: nil

  defp tokens_line(row) do
    case tokens(row, :tokens) do
      "—" -> nil
      amount -> amount <> " tokens"
    end
  end

  # Where a person comes from, said quietly under the name. A Slack member's
  # links to their profile, the way every person links to Slack; the name
  # itself opens their requests, like every other row here (Andrew,
  # 2026-10-03: "slack" should not be same as large and same style as username
  # link).
  defp source(%{source: "slack", workspace: workspace, actor: actor} = row) do
    case Names.person(workspace, actor) do
      %{href: href} when is_binary(href) ->
        source_mark(%{__changed__: nil, href: href, source: row.source})

      _no_profile ->
        source_mark(%{__changed__: nil, href: nil, source: row.source})
    end
  end

  defp source(row), do: source_mark(%{__changed__: nil, href: nil, source: row.source})

  defp source_mark(assigns) do
    assigns =
      assign(assigns, name: source_name(assigns.source), icon: source_icon(assigns.source))

    ~H"""
    <a :if={@href} class="usage-source" href={@href} target="_blank" rel="noopener noreferrer"><Components.icon
      :if={@icon}
      name={@icon}
    />{@name}</a><span :if={!@href} class="usage-source"><Components.icon :if={@icon} name={@icon} />{@name}</span>
    """
  end

  defp source_icon("slack"), do: :slack
  defp source_icon("github"), do: :github
  defp source_icon("webhook"), do: :plug
  defp source_icon(_source), do: nil

  defp per_request(%{requests: requests} = row) when requests > 0 do
    if measured_cost?(row), do: usd(cost(row) / requests), else: "—"
  end

  defp per_request(_row), do: "—"

  defp failed(%{unsuccessful: 0}), do: "None"

  defp failed(%{unsuccessful: failed, attempts: runs}) when is_integer(failed),
    do: "#{number(failed)} of #{number(runs)}"

  defp failed(_row), do: "None"

  # What an empty breakdown means. Channels are Slack channels and people are
  # people in Slack or GitHub, so either is empty while Chat work ran; "No
  # activity in this period" there contradicted the totals above it.
  defp empty("channel"),
    do: {"No work came from a Slack channel in this period", "Chat is not listed by channel."}

  defp empty("person"),
    do:
      {"No work came from a person in Slack or GitHub in this period",
       "Chat is not listed by person."}

  defp empty(_by),
    do: {"No activity in this period", "Choose a longer window to see earlier work."}

  defp missing_identity?(row, "account"), do: is_nil(row.profile)
  defp missing_identity?(row, "work-type"), do: row.work_kind not in @work_kinds
  defp missing_identity?(row, "person"), do: is_nil(row.actor)

  defp missing_identity?(row, "model"),
    do: is_nil(row.model)

  defp missing_identity?(_row, _by), do: false

  # Learning spends on batches of conversation inputs, never on an episode.
  defp kind_link("learning", label, _params, _snapshot),
    do: link_to(label, "/memory/learning")

  # Self-analysis spends on requests people were unhappy with, one model call
  # each, and belongs to no request of its own.
  defp kind_link("self_analysis", label, _params, _snapshot),
    do: link_to(label, "/feedback/fix")

  # Reading each repository for its RYKER.md belongs to no request either.
  defp kind_link("repository_knowledge", label, _params, _snapshot),
    do: link_to(label, "/repositories")

  defp kind_link(_kind, label, params, snapshot), do: entity_link(label, params, snapshot)

  defp entity_link(label, params, snapshot) do
    params =
      Map.new(params, fn {k, v} -> {"usage_#{k}", v || ""} end)
      |> Map.merge(%{
        "mode" => Map.get(snapshot, :mode, "live"),
        "usage_window" => snapshot.window
      })

    link_to(label, "/activity?" <> Paths.encode_query(params))
  end

  defp link_to(label, href), do: link_mark(%{__changed__: nil, label: label, href: href})

  defp link_mark(assigns) do
    ~H"""
    <a href={@href}>{@label}</a>
    """
  end

  # A work type names what the execution bought, not an internal taxonomy.
  # "Admission", "Standard work" and "Deep work" were the router's own words for
  # its compute tiers and told an operator reading a cost page nothing.
  def kind_name("admission"), do: "Routing"
  def kind_name("learning"), do: "Learning"
  def kind_name("self_analysis"), do: "Self-analysis"
  def kind_name("repository_knowledge"), do: "Repository knowledge"
  def kind_name("conversational"), do: "Conversation"
  def kind_name("standard"), do: "Investigation"
  def kind_name("deep"), do: "Deep investigation"
  def kind_name("continuation"), do: "Continuation"
  def kind_name("resumed"), do: "Resumed work"
  def kind_name("task"), do: "Task"
  def kind_name("event_wait"), do: "Event wait"
  def kind_name("schedule"), do: "Scheduled run"
  def kind_name("publication"), do: "Publication follow-up"
  def kind_name("approval"), do: "Approval"
  def kind_name(value), do: Words.label(value || "unclassified")

  # By channel lists Slack channels; a row from anywhere else is named by its
  # own reference rather than passed off as a Slack channel.
  defp channel(%{transport: "slack", conversation_ref: ref}) do
    Names.destination(if String.starts_with?(ref, "slack:"), do: ref, else: "slack:" <> ref)
  end

  defp channel(row), do: "#{row.transport}:#{row.conversation_ref}"

  defp user(%{source: "slack", workspace: workspace, actor: actor}),
    do: Names.name(workspace, actor)

  defp user(row), do: row.actor

  # Where a user comes from, said quietly under the name.
  defp source_name("slack"), do: "Slack"
  defp source_name("github"), do: "GitHub"
  defp source_name("webhook"), do: "Webhook"
  defp source_name(source), do: Words.label(source)

  defp timing(totals) do
    segments = [
      {"Waiting for a worker", value(totals, :queued_ms), "queue"},
      {"Model", value(totals, :provider_ms), "execution"},
      {"Checking the answer", value(totals, :host_ms), "host"}
    ]

    total = Enum.sum(Enum.map(segments, &elem(&1, 1)))

    if total == 0 do
      Kit.empty_html(
        variant: :bare,
        icon: :clock,
        title: "No timing recorded yet",
        text: "How long work waited and ran shows here once Ryker works."
      )
    else
      {arcs, _} =
        Enum.map_reduce(segments, 0, fn {label, ms, class}, offset ->
          portion = ms / total * 100

          arc = [
            "<circle class=\"timing-",
            class,
            "\" cx=\"80\" cy=\"80\" r=\"62\" pathLength=\"100\" stroke-dasharray=\"",
            coordinate(portion),
            " ",
            coordinate(100 - portion),
            "\" stroke-dashoffset=\"",
            coordinate(-offset),
            "\"><title>",
            label,
            ": ",
            duration(ms),
            "</title></circle>"
          ]

          {arc, offset + portion}
        end)

      [
        "<div class=\"usage-donut\"><svg viewBox=\"0 0 160 160\" role=\"img\" aria-label=\"Time spent waiting for a worker, in the model and checking the answer\"><title>Where the time went</title>",
        arcs,
        "<text x=\"80\" y=\"77\" text-anchor=\"middle\">",
        duration(total),
        "</text><text class=\"donut-caption\" x=\"80\" y=\"96\" text-anchor=\"middle\">total time</text></svg><dl>",
        Enum.map(segments, fn {label, ms, class} ->
          [
            "<div><dt><span class=\"timing-key timing-",
            class,
            "\"></span>",
            label,
            "</dt><dd>",
            duration(ms),
            "<span>",
            e(percent(ms / total)),
            "</span></dd></div>"
          ]
        end),
        "</dl></div>"
      ]
    end
  end

  # The saved prices that made this period's estimates, read the way Settings
  # › Model prices reads them. A model priced at two rates in the period says
  # the day each began; reasoning gets a column only when a price charges it.
  defp methodology(snapshot) do
    case Map.get(snapshot, :prices, []) do
      [] -> []
      prices -> rates_used(prices)
    end
  end

  defp rates_used(prices) do
    repeated =
      prices
      |> Enum.frequencies_by(& &1.execution_target)
      |> Enum.flat_map(fn {target, count} -> if count > 1, do: [target], else: [] end)

    reasoning? = Enum.any?(prices, &(&1.reasoning_usd_per_million != nil))

    [
      "<details class=\"measurement-notes\" id=\"cost-method\"><summary>Rates used for estimates</summary>",
      "<div class=\"table-wrap\"><table class=\"usage-pricing-table\"><thead><tr><th>Model</th><th>Fresh input</th><th>Cache reads</th><th>Output</th>",
      if(reasoning?, do: "<th>Reasoning</th>", else: ""),
      "</tr></thead><tbody>",
      Enum.map(prices, fn price ->
        [
          "<tr><td>",
          e(price_model(price.execution_target)),
          if(price.execution_target in repeated,
            do: secondary("from " <> SettingsRows.short_date(price.effective_from)),
            else: ""
          ),
          "</td><td>",
          e(rate(price.input_usd_per_million)),
          "</td><td>",
          e(rate(price.cached_input_usd_per_million)),
          "</td><td>",
          e(rate(price.output_usd_per_million)),
          "</td>",
          if(reasoning?,
            do: ["<td>", e(rate(price.reasoning_usd_per_million)), "</td>"],
            else: ""
          ),
          "</tr>"
        ]
      end),
      "</tbody></table></div><p class=\"usage-rates-note\">USD per million tokens. API-equivalent rates, not subscription charges. ",
      "<a href=\"/settings/prices\">Change these in Settings › Model prices</a></p>",
      "</details>"
    ]
  end

  defp price_model(target) do
    case ExecutionTarget.parts(target) do
      %{model: model} -> model
      nil -> target
    end
  end

  defp rate(nil), do: "—"
  defp rate(price), do: SettingsRows.usd(price)

  defp elapsed(nil), do: "—"
  defp elapsed(ms) when ms < 60_000, do: decimal(ms / 1000) <> "s"

  defp elapsed(ms) do
    seconds = round(ms / 1000)
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    rest = rem(seconds, 60)

    [{hours, "h"}, {minutes, "m"}, {rest, "s"}]
    |> Enum.reject(fn {count, _} -> count == 0 end)
    |> Enum.map_join(" ", fn {count, unit} -> "#{count}#{unit}" end)
  end

  defp value(row, key), do: Map.get(row, key) || 0

  defp share(row, total),
    do:
      if(value(total, :tokens) > 0 and value(row, :usage_measured) > 0,
        do: value(row, :tokens) / total.tokens
      )

  defp secondary(text), do: ["<span class=\"usage-secondary\">", e(text), "</span>"]
  defp cost(row), do: UsageProjection.cost(row)
  defp measured_cost?(row), do: value(row, :costed) + value(row, :estimated) > 0

  defp usd(amount) when amount > 0 and amount < 0.01,
    do: "$" <> :erlang.float_to_binary(amount, decimals: 4)

  defp usd(amount), do: "$" <> :erlang.float_to_binary(amount * 1.0, decimals: 2)

  defp money(%{attempts: 0}), do: "$0.00"

  defp money(row) do
    if value(row, :costed) + value(row, :estimated) > 0 do
      cost = Decimal.add(value(row, :cost_usd), value(row, :estimated_cost_usd))

      precision =
        if Decimal.compare(cost, Decimal.new(0)) == :gt and
             Decimal.compare(cost, Decimal.new("0.01")) == :lt, do: 4, else: 2

      "$" <> Decimal.to_string(Decimal.round(cost, precision), :normal)
    else
      "Not measured"
    end
  end

  defp tokens(row, key),
    do:
      if(Map.get(row, :usage_measured, Map.get(row, :measured, 0)) > 0,
        do: compact(value(row, key)),
        else: "—"
      )

  defp number(n), do: to_string(n) |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  defp compact(n) when n >= 1_000_000,
    do:
      (:erlang.float_to_binary(n / 1_000_000, decimals: 2)
       |> String.trim_trailing("0")
       |> String.trim_trailing(".")) <> "M"

  defp compact(n) when n >= 1000, do: decimal(n / 1000) <> "k"
  defp compact(n), do: number(n)
  defp decimal(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1) |> String.trim_trailing(".0")
  defp coordinate(n), do: :erlang.float_to_binary(n * 1.0, decimals: 3)
  defp percent(nil), do: "—"
  defp percent(n) when n > 0 and n < 0.001, do: "<0.1%"
  defp percent(n), do: decimal(n * 100) <> "%"
  defp duration(nil), do: "—"
  defp duration(ms) when ms >= 3_600_000, do: decimal(ms / 3_600_000) <> "h"
  defp duration(ms) when ms >= 60_000, do: decimal(ms / 60_000) <> "m"
  defp duration(ms), do: decimal(ms / 1000) <> "s"
  defp e(nil), do: ""
  defp e(text), do: Plug.HTML.html_escape(to_string(text))
end
