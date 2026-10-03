defmodule Ryker.ControlPlane.UsagePageTest do
  use Ryker.DataCase, async: false
  alias Ryker.Accounting.Execution
  alias Ryker.ControlPlane.{Activity, Assets, SettingsRows, UsagePage, UsageProjection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Settings
  alias Ryker.Slack.Input

  @actor "control-plane:local"

  test "usage shows live work by default without an execution ledger or generic methodology" do
    html = UsageProjection.page(%{}) |> UsagePage.render() |> IO.iodata_to_binary()

    for label <- [
          "Requests",
          "Total tokens",
          "Fresh input",
          "Cached input",
          "Output",
          "Reasoning",
          "Cache hit rate",
          "Token usage over time",
          "Where the time went",
          "Where the money went"
        ] do
      assert html =~ label
    end

    refute html =~ "<h2>Measurement coverage"
    refute html =~ "Coop profiles"
    # The part of a model's name after the @ is the account it ran on, the
    # word Settings › Models and every other page use.
    refute html |> LazyHTML.from_fragment() |> LazyHTML.text() =~ ~r/profile/i
    refute html =~ "UTC · empty days"
    refute html =~ "id=\"cost-method\""
    refute html =~ "Individual executions"
    refute html =~ "Execution ledger"
    refute html =~ "Each execution contributes one cost"
    refute html =~ "Dates use UTC"
    assert html =~ "Evaluations"
    document = LazyHTML.from_document(html)

    assert document |> LazyHTML.query(".usage-scope [aria-current=page]") |> LazyHTML.text() ==
             "Live work"
  end

  # Andrew, 2026-10-03, of six tables of token columns with the cost cut off at
  # the right edge: "the way you built those tables is piece of shit, they are
  # useless, what i am supposed to do or learn by looking at them?" One table
  # answers one question at a time: what each kind of work cost, most first,
  # its share, what one request cost and how many runs failed.
  test "usage ranks where the money went, most first, one breakdown at a time" do
    # Learning: two runs, one failed, no request of its own.
    for status <- ~w(completed failed) do
      execution!("learning",
        status: status,
        usage_cost_recorded: true,
        usage_cost_usd: Decimal.new("1.50")
      )
    end

    {:ok, %{episode: routed}} = Episodes.apply(EpisodeFixtures.admit_input())

    execution!("admission",
      episode_id: routed.id,
      execution_target: "codex:gpt-5.6-luna/low@default",
      usage_cost_recorded: true,
      usage_cost_usd: Decimal.new("1.00")
    )

    breakdown = page(%{}) |> LazyHTML.query("#usage-breakdown")

    assert text(breakdown, ".section-head h2") == "Where the money went"
    assert text(breakdown, ".section-head p") == "What each kind of work cost, most first."

    assert texts(breakdown, "thead th") ==
             ["Work type", "Share of cost", "Cost", "Requests", "Per request", "Failed runs"]

    assert cells(breakdown) == [
             ["Learning", "75%", "$3.00", "—", "—", "1 of 2"],
             ["Routing", "25%", "$1.00", "1", "$1.00", "None"]
           ]

    # The line under a name says how it ran and on what, quietly.
    assert text(breakdown, "tbody tr:last-child small") == "1 run · on gpt-5.6-luna/low"

    # One question at a time: the switch above the table, work type first.
    assert texts(breakdown, ".segmented a") ==
             ["Work type", "Model", "Channel", "Repository", "Person", "Account"]

    assert texts(breakdown, ".segmented a[aria-current=page]") == ["Work type"]

    # No token columns: the period's tokens are in the summary above.
    refute LazyHTML.text(breakdown) =~ "Fresh input"
    refute LazyHTML.text(breakdown) =~ "Cached input"

    models = page(%{"by" => "model"}) |> LazyHTML.query("#usage-breakdown")
    assert texts(models, ".segmented a[aria-current=page]") == ["Model"]

    assert text(models, ".section-head p") ==
             "What each model cost, and how often its runs failed."

    assert Enum.map(cells(models), &Enum.take(&1, 3)) == [
             ["gpt-5.6-sol/medium", "75%", "$3.00"],
             ["gpt-5.6-luna/low", "25%", "$1.00"]
           ]
  end

  # Andrew, 2026-10-03: "why the fuck you added Local routing model and Where
  # it decided differently to usage and costs?!" It is on its own page beside
  # its setting (`Ryker.ControlPlane.LocalRoutingPageTest`).
  test "usage and cost says nothing about the local routing model" do
    execution!("admission", [])
    words = page(%{}) |> LazyHTML.text()

    for heading <- [
          "Local routing model",
          "Where it decided differently",
          "Answers routing refused"
        ],
        do: refute(words =~ heading)

    refute {Ryker.LocalRouting, :subscribe_comparisons, []} in UsagePage.subscriptions()
  end

  test "the period, the scope and the breakdown each keep the other two" do
    document = page(%{"window" => "30d", "mode" => "all", "by" => "person"})

    for href <-
          hrefs(document, ".usage-filters a") ++ hrefs(document, "#usage-breakdown .segmented a") do
      query = URI.decode_query(URI.parse(href).query)
      assert Map.keys(query) |> Enum.sort() == ["by", "mode", "window"], href
    end

    assert Enum.all?(hrefs(document, ".windows:not(.usage-scope) a"), &(&1 =~ "by=person"))
    assert Enum.all?(hrefs(document, "#usage-breakdown .segmented a"), &(&1 =~ "window=30d"))
    assert UsageProjection.page(%{"by" => "nonsense"}).by == "work-type"
  end

  test "a model reads as one label, with how long a run took and how many answers went back" do
    snapshot = UsageProjection.page(%{"by" => "model"})

    model =
      Map.merge(snapshot.totals, %{
        attempts: 1,
        usage_measured: 1,
        tokens: 43_029,
        input_tokens: 41_500,
        cached_input_tokens: 800,
        output_tokens: 729,
        reasoning_tokens: 25,
        corrections: 2,
        model: "gpt-5.6-sol",
        effort: "high",
        provider: "codex",
        average_provider_ms: 78_000
      })

    breakdown =
      %{snapshot | rows: [model]}
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#usage-breakdown")

    assert text(breakdown, "tbody td:first-child a") == "gpt-5.6-sol/high"

    assert text(breakdown, "tbody small") ==
             "codex · 1 run · 1m 18s a run · 2 corrections · 43k tokens"

    refute LazyHTML.text(breakdown) =~ "High effort"
  end

  test "estimate rates do not repeat spend totals already shown in the usage breakdowns" do
    for effort <- ~w(medium high) do
      execution!("work",
        execution_target: "codex:gpt-5.6-sol/#{effort}@default",
        usage_input_tokens: 1_000,
        usage_cached_input_tokens: 9_000,
        usage_output_tokens: 500
      )
    end

    execution!("work",
      execution_target: "codex:gpt-5.6-terra/medium@default",
      usage_cached_input_tokens: 0,
      usage_output_tokens: 0,
      usage_cost_recorded: true,
      usage_cost_usd: Decimal.new("0.50")
    )

    document =
      UsageProjection.page(%{})
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    pricing = LazyHTML.query(document, "#cost-method")
    assert LazyHTML.text(pricing) =~ "Rates used for estimates"
    refute LazyHTML.text(pricing) =~ "$0.54"
    refute LazyHTML.text(pricing) =~ "$0.50"
    refute LazyHTML.text(pricing) =~ "executions"

    # Both efforts were priced by the one price saved for the model, and the
    # model that reported its own cost used none.
    assert rows(pricing, "tbody tr") == [["gpt-5.6-sol", "$4.00", "$0.40", "$20.00"]]

    # 2 × $0.0176 estimated + $0.50 reported.
    assert LazyHTML.query(document, ".usage-summary .usage-cost") |> LazyHTML.text() =~ "$0.54"
  end

  # Andrew, 2026-09-25: the rates table sat flush under "Rates used for
  # estimates" with its note glued under it in body text, and nothing said
  # where the rates are set. The table now opens 12px under the summary, the
  # note sits 8px under it in the secondary colour, and it ends with the way
  # to change them.
  test "the estimate rates end with the way to change them in Settings" do
    execution!("work", usage_cached_input_tokens: 0, usage_output_tokens: 0)

    document =
      UsageProjection.page(%{})
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    [note] =
      LazyHTML.query(document, "#cost-method > .table-wrap + p.usage-rates-note")
      |> Enum.to_list()

    assert note |> LazyHTML.text() |> String.split() |> Enum.join(" ") ==
             "USD per million tokens. API-equivalent rates, not subscription charges. " <>
               "Change these in Settings › Model prices"

    assert LazyHTML.query(note, "a[href='/settings/prices']") |> LazyHTML.text() ==
             "Change these in Settings › Model prices"

    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    [_, table] = Regex.run(~r/\.usage-page #cost-method > \.table-wrap \{([^}]+)\}/, css)
    assert table =~ "margin-top:12px"
    [_, rates] = Regex.run(~r/#cost-method > \.usage-rates-note \{([^}]+)\}/, css)
    assert rates =~ "margin-top:8px"
    assert rates =~ "color:var(--ryker-text-secondary)"
  end

  # Found in manual testing on 2026-09-26: edits to Model prices never changed
  # any estimate. "Rates used for estimates" listed rates compiled into Ryker,
  # so it showed prices nobody had saved and never one they had.
  test "the rates used for estimates are the saved prices that made them" do
    {:ok, _snapshot} = Settings.initialize(@actor)
    now = DateTime.utc_now()
    yesterday = Date.add(DateTime.to_date(now), -1)

    # The price saved from 5 Sep priced three days ago; a new one from
    # yesterday priced today.
    save_price!(%{
      execution_target: "codex:gpt-5.6-sol",
      input_usd_per_million: "5",
      cached_input_usd_per_million: "0.50",
      output_usd_per_million: "25",
      effective_from: yesterday,
      provenance: "https://developers.openai.com/api/docs/pricing"
    })

    # A newly signed-in provider whose price bills reasoning on its own.
    save_price!(%{
      execution_target: "claude:claude-sonnet-5",
      input_usd_per_million: "3",
      cached_input_usd_per_million: "0.30",
      output_usd_per_million: "15",
      reasoning_usd_per_million: "15",
      effective_from: "2026-09-01",
      provenance: "https://www.anthropic.com/pricing"
    })

    tokens = [usage_cached_input_tokens: 0, usage_output_tokens: 0, usage_reasoning_tokens: 0]

    execution!(
      "work",
      [
        execution_target: "codex:gpt-5.6-sol/medium@default",
        recorded_at: DateTime.add(now, -3, :day)
      ] ++ tokens
    )

    execution!("work", [execution_target: "codex:gpt-5.6-sol/high@default"] ++ tokens)
    execution!("work", [execution_target: "claude:claude-sonnet-5/high@default"] ++ tokens)

    # Luna reported its own cost, so no price of its made an estimate.
    execution!(
      "work",
      [
        execution_target: "codex:gpt-5.6-luna/low@default",
        usage_cost_recorded: true,
        usage_cost_usd: Decimal.new("0.01")
      ] ++ tokens
    )

    pricing =
      UsageProjection.page(%{})
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#cost-method")

    assert rows(pricing, "thead tr") == [
             ["Model", "Fresh input", "Cache reads", "Output", "Reasoning"]
           ]

    # A model priced at two rates in the period says the day each began.
    assert rows(pricing, "tbody tr") == [
             ["claude-sonnet-5", "$3.00", "$0.30", "$15.00", "$15.00"],
             [
               "gpt-5.6-sol" <> "from " <> SettingsRows.short_date(~D[2026-09-05]),
               "$4.00",
               "$0.40",
               "$20.00",
               "—"
             ],
             [
               "gpt-5.6-sol" <> "from " <> SettingsRows.short_date(yesterday),
               "$5.00",
               "$0.50",
               "$25.00",
               "—"
             ]
           ]
  end

  test "an execution without a saved model is not presented as an unknown model" do
    # Four historical failures appeared as a model row with no useful measurements.
    snapshot = UsageProjection.page(%{"by" => "model"})
    totals = %{snapshot.totals | attempts: 4}
    model = Map.merge(totals, %{model: nil, effort: nil, provider: "unrecorded"})

    html =
      %{snapshot | totals: totals, rows: [model]} |> UsagePage.render() |> IO.iodata_to_binary()

    document = LazyHTML.from_document(html)
    refute html =~ "Unknown model"
    assert LazyHTML.query(document, "#usage-breakdown tbody tr") |> Enum.to_list() == []
  end

  test "the page narrates no gaps: no missing token reports, unsaved identities or performance caveat" do
    # Andrew, 2026-09-19: "25 executions have no token report", "5 executions
    # without a saved work type" and the caveat under Model performance were
    # noise on a page he reads for totals. Unmeasured rows still show "—" and
    # "Not measured" where they appear; the page stops narrating the gaps.
    for {by, row} <- [
          {"model", %{model: nil, effort: nil, provider: "unrecorded"}},
          {"account", %{profile: nil, provider: "unrecorded"}},
          {"work-type", %{work_kind: "unclassified"}},
          {"person", %{actor: nil, source: "slack", workspace: "T123"}}
        ] do
      snapshot = UsageProjection.page(%{"by" => by})
      totals = %{snapshot.totals | attempts: 4}

      html =
        %{snapshot | totals: totals, rows: [Map.merge(totals, Map.put(row, :requests, 2))]}
        |> UsagePage.render()
        |> IO.iodata_to_binary()

      refute html =~ "no token report"
      refute html =~ "without a saved"
      refute html =~ "answer-quality"
      refute html =~ "transport retries"
      refute html =~ "Model performance by work type"
    end
  end

  test "accounts are flat and missing metadata is not presented as an account or work type" do
    # Old runs created fake profiles and work types that could not explain any activity.
    snapshot = UsageProjection.page(%{"by" => "account"})
    row = Map.merge(snapshot.totals, %{attempts: 4, requests: 2})

    accounts = [
      Map.merge(row, %{profile: "emisar", provider: "codex"}),
      Map.merge(row, %{profile: nil, provider: "unrecorded"})
    ]

    document =
      %{snapshot | rows: accounts}
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    assert length(LazyHTML.query(document, "#usage-breakdown tbody tr") |> Enum.to_list()) == 1
    assert texts(document, "#usage-breakdown thead th") |> hd() == "Account"
    refute LazyHTML.text(document) =~ ~r/profile/i
    refute LazyHTML.text(document) =~ "Unattributed"

    kinds = %{
      UsageProjection.page(%{})
      | rows: [Map.put(row, :work_kind, "unclassified")]
    }

    html = kinds |> UsagePage.render() |> IO.iodata_to_binary()
    refute html =~ "Unclassified work"

    assert html
           |> LazyHTML.from_document()
           |> LazyHTML.query("#usage-breakdown tbody tr")
           |> Enum.to_list() ==
             []
  end

  test "people focus on requests and cost instead of provider internals" do
    snapshot = UsageProjection.page(%{"by" => "person"})

    person =
      Map.merge(snapshot.totals, %{
        attempts: 2,
        requests: 1,
        actor: "andrew",
        source: "github",
        workspace: "emisar"
      })

    document =
      %{snapshot | rows: [person]}
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    assert texts(document, "#usage-breakdown thead th") |> hd() == "Person"
    assert document |> LazyHTML.query("#usage-breakdown tbody tr") |> LazyHTML.text() =~ "andrew"
    refute document |> LazyHTML.query("#usage-breakdown") |> LazyHTML.text() =~ ~r/reasoning/i
  end

  # Andrew, 2026-09-19: "By person" became "By user", and a name alone did not
  # say whether it belonged to a Slack member, a GitHub account or a webhook.
  # Andrew, 2026-10-03, of "Slack" under "@Andrew" in the same mint and size as
  # the name: ""slack" should not be same as large and same style as username
  # link to episodes, style them properly, you can use an icon if you want".
  test "each person says quietly where they come from, with the place's mark" do
    snapshot = UsageProjection.page(%{"by" => "person"})
    row = Map.merge(snapshot.totals, %{attempts: 1, requests: 1})

    people =
      for {source, actor} <- [{"slack", "U123"}, {"github", "andrew"}, {"webhook", "deploys"}],
          do: Map.merge(row, %{source: source, actor: actor, workspace: "T123"})

    document =
      %{snapshot | rows: people}
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    rows = document |> LazyHTML.query("#usage-breakdown tbody tr") |> Enum.to_list()

    # The source is part of the quiet line under the name, never a second name.
    assert Enum.map(rows, &text(&1, "small .usage-source")) == ["Slack", "GitHub", "Webhook"]

    assert Enum.map(rows, &(&1 |> LazyHTML.query("small .usage-source svg") |> Enum.count())) == [
             1,
             1,
             1
           ]

    # A Slack member reads as a person, never their ID, and "Slack" beneath
    # the name opens their profile, the way every person links to Slack
    # (Andrew, 2026-09-26). The name itself still opens their requests.
    [slack, github, _webhook] = rows
    refute LazyHTML.text(slack) =~ "U123"

    assert slack |> LazyHTML.query("small a.usage-source") |> LazyHTML.attribute("href") == [
             "https://slack.com/app_redirect?team=T123&channel=U123"
           ]

    assert slack |> LazyHTML.query(".usage-name a") |> LazyHTML.attribute("href") |> hd() =~
             "/activity?"

    assert github |> LazyHTML.query("small a") |> Enum.empty?()

    # Quiet: the secondary colour, not the name's.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    [_, link] = Regex.run(~r/\.kit-table td small a\.usage-source \{([^}]+)\}/, css)
    assert link =~ "color:var(--ryker-text-secondary)"
  end

  test "names are escaped and reported and estimated cost add up to one figure" do
    snapshot = UsageProjection.page(%{"by" => "account"})

    row =
      Map.merge(snapshot.totals, %{
        attempts: 2,
        requests: 1,
        usage_measured: 1,
        provider: "codex",
        profile: "<script>profile</script>",
        costed: 1,
        cost_usd: Decimal.new("1.00"),
        estimated: 1,
        estimated_cost_usd: Decimal.new("0.25")
      })

    html = %{snapshot | rows: [row]} |> UsagePage.render() |> IO.iodata_to_binary()
    assert html =~ "&lt;script&gt;profile&lt;/script&gt;"
    refute html =~ "<script>profile</script>"
    assert html =~ "$1.25"
    refute html =~ "reported +"
    refute html =~ "≈ $"
  end

  test "unmeasured groups are not presented as zero tokens and tiny timing shares remain visible" do
    snapshot = UsageProjection.page(%{"by" => "account"})

    row = Map.merge(snapshot.totals, %{attempts: 1, provider: "codex", profile: "emisar"})

    totals =
      Map.merge(snapshot.totals, %{
        tokens: 100,
        provider_ms: 100_000,
        host_ms: 1,
        queued_ms: 100,
        timed: 1
      })

    html =
      %{snapshot | rows: [row], totals: totals} |> UsagePage.render() |> IO.iodata_to_binary()

    breakdown = html |> LazyHTML.from_document() |> LazyHTML.query("#usage-breakdown")
    refute LazyHTML.text(breakdown) =~ "0 tokens"
    assert cells(breakdown) == [["emisar", "—", "Not measured", "—", "—", "None"]]
    assert html =~ "<0.1%" or html =~ "&lt;0.1%"
    # QA re-test, 2026-09-26: the chart said "Host processing". It names the
    # parts the way the request timeline does.
    assert html =~ "Time spent waiting for a worker, in the model and checking the answer"

    for label <- ["Waiting for a worker", "Model", "Checking the answer"] do
      assert html =~ "</span>#{label}</dt>"
    end

    refute html =~ "Host processing"
  end

  test "work types people and sub-cent costs remain useful in populated breakdowns" do
    snapshot = UsageProjection.page(%{})

    row =
      Map.merge(snapshot.totals, %{
        attempts: 1,
        requests: 1,
        usage_measured: 1,
        tokens: 1_200_000,
        input_tokens: 1_100_000,
        cached_input_tokens: 50_000,
        output_tokens: 50_000,
        costed: 0,
        estimated: 1,
        estimated_cost_usd: Decimal.new("0.0012"),
        provider_ms: 3_600_000,
        average_provider_ms: 3_600_000,
        timed: 1
      })

    kinds =
      Enum.map(
        ~w(conversational standard deep continuation resumed task event_wait schedule publication approval unclassified),
        &Map.put(row, :work_kind, &1)
      )

    html =
      %{snapshot | totals: row, rows: kinds}
      |> UsagePage.render()
      |> IO.iodata_to_binary()

    for label <- [
          "Conversation",
          "Investigation",
          "Deep investigation",
          "Continuation",
          "Resumed work",
          "Task",
          "Event wait",
          "Scheduled run",
          "Publication follow-up",
          "Approval",
          "$0.0012",
          "1h a run"
        ] do
      assert html =~ label
    end

    people =
      Enum.map([{"github", "andrew"}, {"slack", "U123"}], fn {source, actor} ->
        Map.merge(row, %{source: source, actor: actor, workspace: "T123"})
      end)

    html =
      %{snapshot | totals: row, rows: people, by: "person"}
      |> UsagePage.render()
      |> IO.iodata_to_binary()

    assert html =~ "andrew"
  end

  test "a kind of work names the models it ran on, most runs first" do
    snapshot = UsageProjection.page(%{})
    row = Map.merge(snapshot.totals, %{attempts: 3, requests: 3, work_kind: "task"})

    models = [
      Map.merge(row, %{attempts: 2, model: "gpt-5.6-sol", effort: "xhigh", provider: "codex"}),
      Map.merge(row, %{attempts: 1, model: "gpt-5.6-sol", effort: "medium", provider: "codex"})
    ]

    breakdown =
      %{snapshot | rows: [Map.put(row, :models, models)]}
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#usage-breakdown")

    assert text(breakdown, "tbody small") =~ "3 runs · on gpt-5.6-sol/xhigh and 1 more"

    assert breakdown |> LazyHTML.query("tbody small [title]") |> LazyHTML.attribute("title") ==
             ["gpt-5.6-sol/xhigh, gpt-5.6-sol/medium"]
  end

  test "learning executions are a named work type that opens the memory page" do
    # The background memory learner spends tokens on every batch it judges, and
    # an unnamed work type sent operators to an episode list that can never hold
    # a learning turn.
    snapshot = UsageProjection.page(%{})

    row =
      Map.merge(snapshot.totals, %{
        attempts: 1,
        requests: 0,
        usage_measured: 1,
        tokens: 5_640,
        work_kind: "learning",
        average_provider_ms: 7_500
      })

    document =
      %{snapshot | totals: row, rows: [row]}
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    assert hrefs(document, "#usage-breakdown tbody a") == ["/memory/learning"]
    refute LazyHTML.text(document) =~ "without a saved work type"
  end

  # Self-analysis asks the learning models once per request people were
  # unhappy with; its spend reads as a work type of its own, never as
  # unclassified work, and opens the page that lists what it analyzed.
  test "self-analysis spend reads as its own work type and opens What to fix" do
    execution!("improvement", [])

    snapshot = UsageProjection.page(%{})
    assert [%{work_kind: "self_analysis", attempts: 1}] = snapshot.rows

    document = snapshot |> UsagePage.render() |> IO.iodata_to_binary() |> LazyHTML.from_document()
    assert document |> LazyHTML.query("#usage-breakdown") |> LazyHTML.text() =~ "Self-analysis"
    assert hrefs(document, "#usage-breakdown tbody a") == ["/feedback/fix"]
  end

  test "every request count on Usage opens an Activity list of exactly that many requests" do
    # QA, 2026-09-25: "Routing 21 episodes" opened Activity at "25 items".
    # Usage counted the episodes its executions belonged to, while Activity
    # also lists every message routing read that never became one, so the
    # figure and the list it opened disagreed.
    {:ok, %{episode: episode}} = Episodes.apply(EpisodeFixtures.admit_input())
    execution!("admission", episode_id: episode.id)
    execution!("work", episode_id: episode.id)

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Is checkout healthy?"},
        event_kind: :message,
        event_ref: "Ev-usage-counts",
        message_ref: "1787832099.000100",
        occurred_at: DateTime.utc_now(),
        revision: 1,
        thread_ref: nil,
        workspace_ref: "T123"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    execution!("admission", source_id: entry.id)

    counted =
      for by <- UsageProjection.breakdowns(),
          row <- page(%{"by" => by}) |> LazyHTML.query("#usage-breakdown tbody tr"),
          [href] = row |> LazyHTML.query(".usage-name a") |> LazyHTML.attribute("href"),
          String.starts_with?(href, "/activity?") do
        count = text(row, "td:nth-child(4)")
        name = text(row, ".usage-name a")
        listed = Activity.list(URI.decode_query(URI.parse(href).query)).total

        assert String.to_integer(count) == listed,
               "#{name} (#{by}) says #{count} and opens #{href}, which lists #{listed}"

        name
      end

    assert "Routing" in counted
  end

  test "work that runs without a request says how many runs, never zero requests" do
    # QA, 2026-09-25: Learning read "0 episodes / 16 executions" and one row
    # "1 episodes". Learning spends on conversations, not on requests.
    snapshot = UsageProjection.page(%{})
    row = Map.merge(snapshot.totals, %{attempts: 16, requests: 0, usage_measured: 1})

    kinds = [
      Map.put(row, :work_kind, "learning"),
      Map.merge(row, %{work_kind: "schedule", attempts: 1, requests: 1})
    ]

    breakdown =
      %{snapshot | rows: kinds}
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()
      |> LazyHTML.query("#usage-breakdown")

    assert [learning, schedule] = breakdown |> LazyHTML.query("tbody tr") |> Enum.to_list()
    assert text(learning, "td:nth-child(4)") == "—"
    assert text(learning, "small") =~ ~r/^16 runs\b/
    refute LazyHTML.text(learning) =~ "request"
    assert text(schedule, "td:nth-child(4)") == "1"
    refute LazyHTML.text(breakdown) =~ "episode"
  end

  test "a breakdown that leaves out Chat never says there was no activity" do
    # QA, 2026-09-25: "By channel 0" and "By user 0" each said "No activity in
    # this period" beside $2.15 of work, all of it from Chat, which neither
    # breakdown lists by design.
    execution!("admission",
      transport: "control_plane",
      conversation_ref: "control-plane:lab:" <> Ecto.UUID.generate()
    )

    for {by, words} <- [
          {"channel", "Chat is not listed by channel"},
          {"person", "Chat is not listed by person"}
        ] do
      document = page(%{"by" => by})
      refute LazyHTML.text(document) =~ "No activity in this period"
      assert document |> LazyHTML.query("#usage-breakdown .kit-empty") |> LazyHTML.text() =~ words
    end
  end

  test "a chart or table wider than a phone shows that it scrolls" do
    # QA, 2026-09-25, at 390px: the token chart and every breakdown table were
    # cut at the screen edge with nothing saying they scroll sideways. Each
    # scrolling part now shades the side that has more, and only that side.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    for part <- [".chart-scroll", ".table-wrap", ".kit-table-wrap"] do
      rules =
        ~r/([^{}]+)\{([^}]*)\}/
        |> Regex.scan(css, capture: :all_but_first)
        |> Enum.filter(fn [selector, _body] ->
          selector =~ ".usage-page" and String.contains?(selector, part)
        end)
        |> Enum.map_join(" ", &List.last/1)

      assert rules =~ ~r/background:[^;]*\blocal\b[^;]*\bscroll\b/s,
             "#{part} scrolls on Usage without a cue"
    end
  end

  test "Usage opens on the same work as Activity" do
    # QA, 2026-09-25: Usage opened on All work and Activity on Live work, so
    # the two pages counted different things until a scope was chosen.
    assert UsageProjection.page(%{}).mode == Activity.list(%{}).mode

    document =
      UsageProjection.page(%{})
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query(".usage-scope [aria-current=page]") |> LazyHTML.text() ==
             "Live work"
  end

  defp page(params),
    do:
      params
      |> UsageProjection.page()
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

  defp cells(breakdown) do
    breakdown
    |> LazyHTML.query("tbody tr")
    |> Enum.map(fn row ->
      [name | figures] = row |> LazyHTML.query("td") |> Enum.to_list()
      [text(name, ".usage-name") | Enum.map(figures, &squish(LazyHTML.text(&1)))]
    end)
  end

  defp text(node, selector), do: node |> LazyHTML.query(selector) |> LazyHTML.text() |> squish()

  defp texts(node, selector),
    do: node |> LazyHTML.query(selector) |> Enum.map(&squish(LazyHTML.text(&1)))

  defp hrefs(node, selector), do: node |> LazyHTML.query(selector) |> LazyHTML.attribute("href")

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  defp save_price!(attributes) do
    {:ok, snapshot} =
      Settings.put_pricing_rate(attributes, Settings.fetch!().installation.revision, @actor)

    snapshot
  end

  defp rows(node, selector) do
    node
    |> LazyHTML.query(selector)
    |> Enum.map(fn row ->
      row |> LazyHTML.query("th, td") |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
    end)
  end

  defp execution!(kind, attributes) do
    Repo.insert!(
      struct!(
        Execution,
        Map.merge(
          %{
            kind: kind,
            source_id: Ecto.UUID.generate(),
            generation: "1",
            transport: "slack",
            conversation_ref: "slack:T123:C456",
            execution_mode: "live",
            remote_ref: "usage-counts:" <> Ecto.UUID.generate(),
            status: "completed",
            execution_target: "codex:gpt-5.6-sol/medium@default",
            usage_recorded: true,
            usage_input_tokens: 10,
            recorded_at: DateTime.utc_now()
          },
          Map.new(attributes)
        )
      )
    )
  end
end
