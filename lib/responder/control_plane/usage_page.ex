defmodule Responder.ControlPlane.UsagePage do
  @moduledoc "Usage as an operator's ledger: totals, subscriptions, and the work behind them."
  alias Responder.ControlPlane.{SlackNames, UsageChart}

  def render(snapshot, ledger) do
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
      "</div></div></section><div class=\"usage-charts\"><section class=\"usage-trend-panel\"><h2>Daily tokens</h2>",
      UsageChart.render(snapshot.days),
      "</section><section class=\"usage-timing-panel\"><h2>Where the time went</h2>",
      timing(totals),
      "</section></div>",
      section("Coop profiles", "profiles", Map.get(snapshot, :profiles, []), snapshot, :profile),
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
      section("By person", "people", Map.get(snapshot, :users, []), snapshot, :person),
      "<details class=\"execution-ledger-disclosure\" id=\"execution-ledger\"><summary>Individual executions</summary>",
      ledger,
      "</details>",
      methodology(totals),
      "</div>"
    ]
  end

  defp filters(snapshot) do
    mode = Map.get(snapshot, :mode, "live")

    [
      "<div class=\"usage-filters\"><nav class=\"windows\" aria-label=\"Usage window\">",
      Enum.map(~w(24h 7d 30d all), fn window ->
        filter_link(%{window: window, mode: mode}, window, window == snapshot.window)
      end),
      "</nav><nav class=\"windows usage-scope\" aria-label=\"Execution scope\">",
      Enum.map([{"live", "Live work"}, {"shadow", "Shadow"}, {"all", "All work"}], fn {scope,
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

  defp section(title, id, rows, snapshot, kind) do
    [
      "<section class=\"usage-breakdown\" id=\"usage-",
      id,
      "\"><div class=\"usage-section-heading\"><h2>",
      title,
      "</h2><span>",
      if(length(rows) > 500, do: "500+", else: number(length(rows))),
      "</span></div>",
      breakdown(rows, snapshot, kind),
      "</section>"
    ]
  end

  defp breakdown([], _, _), do: "<p class=\"empty\">No activity in this period.</p>"

  defp breakdown(rows, snapshot, kind) do
    [
      "<div class=\"table-wrap\"><table class=\"usage-breakdown-table\"><thead><tr><th>",
      heading(kind),
      "</th><th>Usage</th><th>Input</th><th>Output</th><th>Performance</th><th>Cost</th></tr></thead><tbody>",
      Enum.map(Enum.take(rows, 500), &row(&1, snapshot, kind)),
      "</tbody></table></div>",
      if(length(rows) > 500,
        do: "<p>Showing the 500 largest groups. Totals include all activity.</p>",
        else: ""
      )
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
      "</td><td>",
      primary(tokens(row, :input_tokens), " fresh"),
      secondary(tokens(row, :cached_input_tokens) <> " cached"),
      "</td><td>",
      primary(tokens(row, :output_tokens), " out"),
      secondary(tokens(row, :reasoning_tokens) <> " reasoning"),
      "</td><td>",
      primary(percent(Map.get(row, :cache_hit_rate)), " cache"),
      secondary(duration(Map.get(row, :average_provider_ms)) <> " / execution"),
      "</td><td class=\"usage-money\">",
      e(money(row)),
      "</td></tr>",
      profile_models(row, snapshot, kind)
    ]
  end

  defp profile_models(%{models: models} = row, snapshot, :profile) when models != [] do
    id = :crypto.hash(:sha256, "#{row.provider}@#{row.profile}") |> Base.encode16(case: :lower)

    [
      "<tr class=\"usage-profile-models\"><td colspan=\"6\"><details id=\"profile-",
      id,
      "\"><summary>Models used by ",
      e(row.profile || "unattributed profile"),
      "</summary>",
      breakdown(models, snapshot, :model),
      if(Map.get(row, :models_truncated, false),
        do:
          "<p>Some model rows are outside the display limit. Profile totals include all executions.</p>",
        else: ""
      ),
      "</details></td></tr>"
    ]
  end

  defp profile_models(_, _, _), do: ""

  defp identity(row, snapshot, :profile) do
    label = row.profile || "Unattributed profile"

    [
      entity_link(label, %{profile: row.profile || "", provider: row.provider}, snapshot),
      secondary(row.provider)
    ]
  end

  defp identity(row, snapshot, :model) do
    params =
      if Map.has_key?(row, :target),
        do: %{target: row.target},
        else: %{model: row.model, provider: row.provider}

    [
      entity_link(
        if(params[:target] == nil and Map.has_key?(params, :target),
          do: "Unknown model",
          else: row.model || "Unknown model"
        ),
        params,
        snapshot
      ),
      secondary(Enum.join(Enum.reject([row.provider, Map.get(row, :effort)], &is_nil/1), " · "))
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
    do: entity_link(kind_name(row.work_kind), %{work_kind: row.work_kind}, snapshot)

  defp identity(row, snapshot, :person),
    do:
      entity_link(
        person(row),
        %{actor: row.actor || "", workspace: row.workspace || "", source: row.source || ""},
        snapshot
      )

  defp entity_link(label, params, snapshot) do
    title = Map.get(params, :target, label)

    params =
      Map.new(params, fn {k, v} -> {"usage_#{k}", v || ""} end)
      |> Map.merge(%{
        "mode" => Map.get(snapshot, :mode, "live"),
        "usage_window" => snapshot.window
      })

    [
      "<a title=\"",
      e(title),
      "\" href=\"/episodes?",
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
  defp heading(:person), do: "Person"
  defp kind_name("admission"), do: "Admission"
  defp kind_name("conversational"), do: "Conversation"
  defp kind_name("standard"), do: "Standard work"
  defp kind_name("deep"), do: "Deep work"
  defp kind_name(_), do: "Unclassified work"

  defp channel(%{transport: "slack", conversation_ref: ref}) do
    SlackNames.destination(if String.starts_with?(ref, "slack:"), do: ref, else: "slack:" <> ref)
  end

  defp channel(%{transport: "control_plane"}), do: "Conversation Lab"
  defp channel(row), do: "#{row.transport}:#{row.conversation_ref}"
  defp person(%{actor: nil}), do: "Automated / unattributed"
  defp person(%{source: "control_plane"}), do: "Conversation Lab"

  defp person(%{source: "slack", workspace: workspace, actor: actor}),
    do: SlackNames.name(workspace, actor)

  defp person(row), do: row.actor

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

  defp methodology(totals) do
    [
      "<details class=\"measurement-notes\" id=\"cost-method\"><summary>How cost is calculated</summary>",
      "<p>Each execution contributes one cost: the provider-reported amount when available, otherwise a token-priced estimate. Subscription profiles show comparative API-equivalent usage, not subscription charges or remaining quota.</p>",
      "<p>Estimates use the built-in standard-context rate card for Codex Sol, Terra and Luna. Fresh input, cache reads and output are priced separately. Reasoning is included in output and is not added again. Provider-specific fees, long-context rates and child-task spend are not reconstructed from aggregate counters.</p>",
      "<p>",
      number(totals.costed),
      " provider-priced · ",
      number(value(totals, :estimated)),
      " estimated · ",
      number(max(totals.attempts - totals.costed - value(totals, :estimated), 0)),
      " unpriced executions. Unpriced activity is excluded from cost, not treated as free.</p>",
      "<p>",
      number(totals.usage_measured),
      " of ",
      number(totals.attempts),
      " executions have token measurements; ",
      number(totals.timed),
      " have timing; ",
      number(totals.measurement_errors),
      " measurement errors. Profile attribution uses the retained execution target, not the current configuration. Missing or ambiguous credentials remain unattributed.</p>",
      "<p>Dates use UTC. Episode counts are distinct within each group; an episode using several models or profiles appears in each relevant group. Overall episode counts are deduplicated.</p></details>"
    ]
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
