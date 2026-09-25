defmodule Ryker.ControlPlane.UsagePage do
  @moduledoc "Usage as an operator's ledger: totals, subscriptions, and the work behind them."
  alias Ryker.Accounting.Pricing
  alias Ryker.ControlPlane.{Components, SlackNames, UsageChart}

  # Every work type the projection can name; anything else is a missing identity.
  @work_kinds ~w(admission learning conversational standard deep continuation resumed task event_wait schedule publication approval)

  def work_kinds, do: @work_kinds

  def render(snapshot) do
    totals = snapshot.totals

    [
      "<div class=\"usage-page\">",
      filters(snapshot),
      "<section class=\"usage-summary\" aria-label=\"Usage summary\"><div class=\"usage-headlines\">",
      stat("Cost", money(totals), "usage-cost"),
      stat("Episodes", number(value(totals, :episodes))),
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
      performance(Map.get(snapshot, :performance, []), snapshot),
      section("By profile", "profiles", Map.get(snapshot, :profiles, []), snapshot, :profile),
      section(
        "By model",
        "models",
        Map.get(snapshot, :models, snapshot.targets),
        snapshot,
        :model
      ),
      section("By channel", "channels", snapshot.channels, snapshot, :channel),
      section("By repository", "repositories", snapshot.repositories, snapshot, :repository),
      section("By work type", "work-types", Map.get(snapshot, :kinds, []), snapshot, :kind),
      section("By user", "users", Map.get(snapshot, :users, []), snapshot, :user),
      methodology(snapshot),
      "</div>"
    ]
  end

  defp performance([], _), do: []

  defp performance(rows, snapshot) do
    [
      "<section id=\"model-performance\" class=\"usage-section\"><h2>Model performance by work type</h2>",
      "<div class=\"table-wrap\"><table class=\"usage-performance-table\"><thead><tr><th>Work type / model</th><th>Executions</th><th>Failed runs</th><th>Response corrections</th><th>Average model time</th></tr></thead><tbody>",
      Enum.map(Enum.take(rows, 500), fn row ->
        [
          "<tr><td>",
          kind_link(
            row.work_kind,
            kind_name(row.work_kind),
            %{
              work_kind: row.work_kind,
              model: row.model,
              provider: row.provider,
              effort: row.effort
            },
            snapshot
          ),
          "<br><small>",
          e(Enum.join(Enum.reject([row.provider, row.model, row.effort], &is_nil/1), " · ")),
          "</small></td><td>",
          e(number(row.attempts)),
          "</td><td>",
          e(number(row.unsuccessful)),
          "</td><td>",
          e(number(row.corrections)),
          "</td><td>",
          e(duration(row.average_provider_ms)),
          "</td></tr>"
        ]
      end),
      "</tbody></table></div></section>"
    ]
  end

  defp filters(snapshot) do
    mode = Map.get(snapshot, :mode, "all")

    [
      "<div class=\"usage-filters\"><nav class=\"windows\" aria-label=\"Usage window\">",
      Enum.map(~w(24h 7d 30d all), fn window ->
        filter_link(%{window: window, mode: mode}, window, window == snapshot.window)
      end),
      "</nav><nav class=\"windows usage-scope\" aria-label=\"Execution scope\">",
      Enum.map([{"all", "All work"}, {"live", "Live work"}, {"shadow", "Evaluations"}], fn {scope,
                                                                                            label} ->
        filter_link(%{window: snapshot.window, mode: scope}, label, scope == mode)
      end),
      "</nav></div>"
    ]
  end

  defp filter_link(params, label, selected) do
    [
      "<a href=\"/usage?",
      e(URI.encode_query(params)),
      "\"",
      if(selected, do: " aria-current=\"page\"", else: ""),
      ">",
      e(label),
      "</a>"
    ]
  end

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

  # A row without a saved identity counts in every total but gets no row or
  # note of its own.
  defp section(title, id, rows, snapshot, kind) do
    known = Enum.reject(rows, &missing_identity?(&1, kind))

    [
      "<section class=\"usage-breakdown\" id=\"usage-",
      id,
      "\"><div class=\"usage-section-heading\"><h2>",
      title,
      "</h2><span>",
      if(length(rows) > 500, do: "500+", else: number(length(known))),
      "</span></div>",
      if(known == [] and rows != [], do: "", else: breakdown(known, snapshot, kind)),
      truncation(rows),
      "</section>"
    ]
  end

  defp breakdown([], _, _), do: "<p class=\"empty\">No activity in this period.</p>"

  defp breakdown(rows, snapshot, :user) do
    [
      "<div class=\"table-wrap\"><table class=\"usage-breakdown-table usage-users-table\"><thead><tr><th>User</th><th>Episodes</th><th>Tokens</th><th>Cost</th></tr></thead><tbody>",
      Enum.map(Enum.take(rows, 500), fn row ->
        [
          "<tr><td class=\"usage-identity\">",
          identity(row, snapshot, :user),
          "</td><td>",
          primary(number(value(row, :episodes)), ""),
          "</td><td>",
          primary(tokens(row, :tokens), ""),
          "</td><td class=\"usage-money\">",
          e(money(row)),
          "</td></tr>"
        ]
      end),
      "</tbody></table></div>"
    ]
  end

  defp breakdown(rows, snapshot, kind) do
    [
      "<div class=\"table-wrap\"><table class=\"usage-breakdown-table usage-detail-table\">",
      "<colgroup><col class=\"usage-name-col\"></colgroup><colgroup><col class=\"usage-count-col\"></colgroup>",
      "<colgroup><col span=\"2\" class=\"usage-token-col\"></colgroup><colgroup><col span=\"2\" class=\"usage-token-col\"></colgroup>",
      "<colgroup><col class=\"usage-performance-col\"></colgroup><colgroup><col class=\"usage-cost-col\"></colgroup>",
      "<thead><tr class=\"usage-column-groups\"><th scope=\"col\" rowspan=\"2\">",
      heading(kind),
      "</th><th scope=\"col\" rowspan=\"2\">Usage</th><th scope=\"colgroup\" colspan=\"2\" class=\"usage-group-start\">Input</th><th scope=\"colgroup\" colspan=\"2\" class=\"usage-group-start\">Output</th>",
      "<th scope=\"col\" rowspan=\"2\" class=\"usage-group-start usage-performance\">Performance</th><th scope=\"col\" rowspan=\"2\" class=\"usage-group-start\">Cost</th></tr>",
      "<tr class=\"usage-metric-headings\"><th scope=\"col\" class=\"usage-group-start\">Fresh input</th><th scope=\"col\">Cached input</th><th scope=\"col\" class=\"usage-group-start\">Output</th><th scope=\"col\">Reasoning</th></tr></thead><tbody>",
      Enum.map(Enum.take(rows, 500), &row(&1, snapshot, kind)),
      "</tbody></table></div>"
    ]
  end

  defp row(row, snapshot, kind) do
    [
      "<tr><td class=\"usage-identity\">",
      identity(row, snapshot, kind),
      "</td><td>",
      primary(number(value(row, :episodes)), " episodes"),
      secondary(number(row.attempts) <> " executions · " <> tokens(row, :tokens) <> " tokens"),
      secondary(percent(share(row, snapshot.totals)) <> " of tokens"),
      "</td>",
      Enum.map([:input_tokens, :cached_input_tokens, :output_tokens, :reasoning_tokens], fn key ->
        [
          "<td class=\"usage-token-cell",
          if(key in [:input_tokens, :output_tokens], do: " usage-group-start", else: ""),
          "\">",
          e(tokens(row, key)),
          "</td>"
        ]
      end),
      "<td class=\"usage-group-start usage-performance\">",
      primary(percent(Map.get(row, :cache_hit_rate)), " cache"),
      secondary("Avg. model time: " <> elapsed(Map.get(row, :average_provider_ms))),
      "</td><td class=\"usage-money usage-group-start\">",
      e(money(row)),
      "</td></tr>"
    ]
  end

  defp truncation(rows),
    do:
      if(length(rows) > 500,
        do: "<p>Showing the 500 largest groups. Totals include all activity.</p>",
        else: ""
      )

  defp missing_identity?(row, :profile), do: is_nil(row.profile)

  defp missing_identity?(row, :kind), do: row.work_kind not in @work_kinds

  defp missing_identity?(row, :user), do: is_nil(row.actor)

  defp missing_identity?(row, :model),
    do: is_nil(row.model) or (Map.has_key?(row, :target) and is_nil(row.target))

  defp missing_identity?(_, _), do: false

  defp identity(row, snapshot, :profile) do
    [
      entity_link(row.profile, %{profile: row.profile, provider: row.provider}, snapshot),
      secondary(row.provider)
    ]
  end

  defp identity(row, snapshot, :model) do
    params =
      if Map.has_key?(row, :target),
        do: %{target: row.target},
        else: %{model: row.model, provider: row.provider, effort: Map.get(row, :effort)}

    [
      entity_link(
        Enum.join(Enum.reject([row.model, Map.get(row, :effort)], &is_nil/1), "/"),
        params,
        snapshot
      ),
      secondary(row.provider || "Provider not saved")
    ]
  end

  defp identity(row, snapshot, :channel),
    do:
      entity_link(
        channel(row),
        %{channel: row.conversation_ref, transport: row.transport},
        snapshot
      )

  defp identity(row, snapshot, :repository),
    do:
      entity_link(
        row.repository_ref || "No repository",
        %{repository: row.repository_ref || ""},
        snapshot
      )

  defp identity(row, snapshot, :kind),
    do: kind_link(row.work_kind, kind_name(row.work_kind), %{work_kind: row.work_kind}, snapshot)

  defp identity(row, snapshot, :user) do
    [
      entity_link(
        user(row),
        %{actor: row.actor, actor_kind: "user", workspace: row.workspace, source: row.source},
        snapshot
      ),
      secondary(source_name(row.source))
    ]
  end

  # Learning spends on batches of conversation inputs, never on an episode.
  defp kind_link("learning", label, _params, _snapshot),
    do: ["<a title=\"Learning\" href=\"/memory/learning\">", e(label), "</a>"]

  defp kind_link(_kind, label, params, snapshot), do: entity_link(label, params, snapshot)

  defp entity_link(label, params, snapshot) do
    title = Map.get(params, :target, label)

    params =
      Map.new(params, fn {k, v} -> {"usage_#{k}", v || ""} end)
      |> Map.merge(%{
        "mode" => Map.get(snapshot, :mode, "all"),
        "usage_window" => snapshot.window
      })

    [
      "<a title=\"",
      e(title),
      "\" href=\"/activity?",
      e(URI.encode_query(params)),
      "\">",
      e(label),
      "</a>"
    ]
  end

  defp heading(:profile), do: "Profile"
  defp heading(:model), do: "Provider / model"
  defp heading(:channel), do: "Channel"
  defp heading(:repository), do: "Repository"
  defp heading(:kind), do: "Work type"
  defp heading(:user), do: "User"
  # A work type names what the execution bought, not an internal taxonomy.
  # "Admission", "Standard work" and "Deep work" were the router's own words for
  # its compute tiers and told an operator reading a cost page nothing.
  def kind_name("admission"), do: "Routing"
  def kind_name("learning"), do: "Learning"
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
  def kind_name(value), do: Components.label(value || "unclassified")

  defp channel(%{transport: "slack", conversation_ref: ref}) do
    SlackNames.destination(if String.starts_with?(ref, "slack:"), do: ref, else: "slack:" <> ref)
  end

  defp channel(%{transport: "control_plane"}), do: "Direct conversation"
  defp channel(row), do: "#{row.transport}:#{row.conversation_ref}"

  defp user(%{source: "slack", workspace: workspace, actor: actor}),
    do: SlackNames.name(workspace, actor)

  defp user(row), do: row.actor

  # Where a user comes from, said quietly under the name.
  defp source_name("slack"), do: "Slack"
  defp source_name("github"), do: "GitHub"
  defp source_name("webhook"), do: "Webhook"
  defp source_name(source), do: Components.label(source)

  defp timing(totals) do
    segments = [
      {"Queue", value(totals, :queued_ms), "queue"},
      {"Execution", value(totals, :provider_ms), "execution"},
      {"Host processing", value(totals, :host_ms), "host"}
    ]

    total = Enum.sum(Enum.map(segments, &elem(&1, 1)))

    if total == 0 do
      "<p class=\"empty\">No execution timing recorded yet.</p>"
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
        "<div class=\"usage-donut\"><svg viewBox=\"0 0 160 160\" role=\"img\" aria-label=\"Time spent in queue, execution and host processing\"><title>Where the time went</title>",
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

  defp methodology(snapshot) do
    rates = Pricing.rates()

    models =
      Map.get(snapshot, :models, snapshot.targets)
      |> Enum.filter(
        &(value(&1, :estimated) > 0 and Map.has_key?(rates, "#{&1.provider}:#{&1.model}"))
      )
      |> Enum.uniq_by(&{&1.provider, &1.model})

    if models == [] do
      []
    else
      [
        "<details class=\"measurement-notes\" id=\"cost-method\"><summary>Rates used for estimates</summary>",
        "<div class=\"table-wrap\"><table class=\"usage-pricing-table\"><thead><tr><th>Model</th><th>Fresh input</th><th>Cache reads</th><th>Output</th></tr></thead><tbody>",
        Enum.map(models, fn row ->
          {input, cached, output} = Map.fetch!(rates, "#{row.provider}:#{row.model}")

          [
            "<tr><td>",
            e(row.model),
            "</td><td>$",
            e(input),
            "</td><td>$",
            e(cached),
            "</td><td>$",
            e(output),
            "</td></tr>"
          ]
        end),
        "</tbody></table></div><p>USD per million tokens. API-equivalent rates, not subscription charges.</p>",
        "</details>"
      ]
    end
  end

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

  defp primary(value, suffix), do: ["<strong>", e(value), "</strong>", e(suffix)]
  defp secondary(text), do: ["<span class=\"usage-secondary\">", e(text), "</span>"]
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
