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
          "By account",
          "Token usage over time",
          "By model",
          "By channel",
          "By repository",
          "By work type",
          "Where the time went"
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

  test "model and effort form one readable label and average model time is explicit" do
    # Operators read 1.3m as a token count; the duration must name what it measures.
    snapshot = UsageProjection.page(%{})

    model =
      Map.merge(snapshot.totals, %{
        attempts: 1,
        usage_measured: 1,
        input_tokens: 41_500,
        cached_input_tokens: 800,
        output_tokens: 729,
        reasoning_tokens: 25,
        model: "gpt-5.6-sol",
        effort: "high",
        provider: "codex",
        average_provider_ms: 78_000
      })

    html = %{snapshot | models: [model]} |> UsagePage.render() |> IO.iodata_to_binary()
    assert html =~ "gpt-5.6-sol/high"
    assert html =~ "Avg. model time: 1m 18s"
    refute html =~ "High effort"
    refute html =~ "/ execution"

    document = LazyHTML.from_document(html)
    headers = LazyHTML.query(document, "#usage-models thead tr:last-child th")

    assert Enum.map(LazyHTML.to_tree(headers), &(LazyHTML.from_tree([&1]) |> LazyHTML.text())) ==
             ["Fresh input", "Cached input", "Output", "Reasoning"]

    cells = LazyHTML.query(document, "#usage-models tbody .usage-token-cell")

    assert Enum.map(LazyHTML.to_tree(cells), &(LazyHTML.from_tree([&1]) |> LazyHTML.text())) ==
             ["41.5k", "800", "729", "25"]

    assert LazyHTML.query(document, "#usage-models th[scope=colgroup]") |> LazyHTML.text() ==
             "InputOutput"

    # Broken group borders made Performance appear to belong to Output.
    assert LazyHTML.query(document, "#usage-models thead tr:first-child .usage-group-start")
           |> LazyHTML.text() == "InputOutputPerformanceCost"

    assert LazyHTML.query(document, "#usage-models colgroup col") |> LazyHTML.attribute("span") ==
             ["2", "2"]

    # Performance used to drift left while every neighboring numeric group was centered.
    assert LazyHTML.query(document, "#usage-models th.usage-performance") |> LazyHTML.text() ==
             "Performance"

    assert LazyHTML.query(document, "#usage-models td.usage-performance") |> LazyHTML.text() =~
             "Avg. model time: 1m 18s"
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
    snapshot = UsageProjection.page(%{})
    totals = %{snapshot.totals | attempts: 4}
    model = Map.merge(totals, %{model: nil, effort: nil, provider: "unrecorded"})

    html =
      %{snapshot | totals: totals, models: [model]} |> UsagePage.render() |> IO.iodata_to_binary()

    document = LazyHTML.from_document(html)
    refute html =~ "Unknown model"
    assert LazyHTML.query(document, "#usage-models tbody tr") |> LazyHTML.to_tree() == []
  end

  test "the page narrates no gaps: no missing token reports, unsaved identities or performance caveat" do
    # Andrew, 2026-09-19: "25 executions have no token report", "5 executions
    # without a saved work type" and the caveat under Model performance were
    # noise on a page he reads for totals. Unmeasured rows still show "—" and
    # "Not measured" where they appear; the page stops narrating the gaps.
    snapshot = UsageProjection.page(%{})
    totals = %{snapshot.totals | attempts: 4}
    row = Map.merge(totals, %{requests: 2})

    html =
      %{
        snapshot
        | totals: totals,
          models: [Map.merge(row, %{model: nil, effort: nil, provider: "unrecorded"})],
          profiles: [Map.merge(row, %{profile: nil, provider: "unrecorded", models: []})],
          kinds: [Map.put(row, :work_kind, "unclassified")],
          users: [Map.merge(row, %{actor: nil, source: "slack", workspace: "T123"})],
          performance: [
            Map.merge(row, %{
              work_kind: "standard",
              provider: "codex",
              model: "gpt-5.6-sol",
              effort: "medium",
              corrections: 0,
              unsuccessful: 0
            })
          ]
      }
      |> UsagePage.render()
      |> IO.iodata_to_binary()

    assert html =~ "Model performance by work type"
    refute html =~ "no token report"
    refute html =~ "without a saved"
    refute html =~ "answer-quality"
    refute html =~ "transport retries"
  end

  test "profiles are flat and missing metadata is not presented as a profile or work type" do
    # Old runs created fake profiles and work types that could not explain any activity.
    snapshot = UsageProjection.page(%{})
    row = Map.merge(snapshot.totals, %{attempts: 4, requests: 2})

    profiles = [
      Map.merge(row, %{
        profile: "emisar",
        provider: "codex",
        models: [Map.merge(row, %{model: "gpt-5.6-sol", provider: "codex", effort: "medium"})]
      }),
      Map.merge(row, %{profile: nil, provider: "unrecorded", models: []})
    ]

    html =
      %{snapshot | profiles: profiles, kinds: [Map.put(row, :work_kind, "unclassified")]}
      |> UsagePage.render()
      |> IO.iodata_to_binary()

    document = LazyHTML.from_document(html)

    assert length(LazyHTML.query(document, "#usage-profiles tbody > tr") |> LazyHTML.to_tree()) ==
             1

    assert LazyHTML.query(document, "#usage-profiles thead th[rowspan='2']")
           |> Enum.map(&LazyHTML.text/1)
           |> hd() == "Account"

    refute LazyHTML.text(document) =~ ~r/profile/i
    assert LazyHTML.query(document, "#usage-profiles details") |> LazyHTML.to_tree() == []
    refute html =~ "Unattributed profile"
    refute html =~ "Unclassified work"
    assert LazyHTML.query(document, "#usage-work-types tbody tr") |> LazyHTML.to_tree() == []
  end

  test "people focus on requests tokens and cost instead of provider internals" do
    snapshot = UsageProjection.page(%{})

    person =
      Map.merge(snapshot.totals, %{
        attempts: 2,
        requests: 1,
        actor: "andrew",
        source: "github",
        workspace: "emisar"
      })

    html = %{snapshot | users: [person]} |> UsagePage.render() |> IO.iodata_to_binary()
    document = LazyHTML.from_document(html)
    headers = document |> LazyHTML.query("#usage-users th") |> LazyHTML.to_tree()

    assert Enum.map(headers, fn node -> LazyHTML.from_tree([node]) |> LazyHTML.text() end) == [
             "User",
             "Requests",
             "Tokens",
             "Cost"
           ]

    assert document |> LazyHTML.query("#usage-users tbody tr") |> LazyHTML.text() =~ "andrew"
    refute document |> LazyHTML.query("#usage-users") |> LazyHTML.text() =~ "reasoning"
  end

  test "each user says quietly where they come from" do
    # Andrew, 2026-09-19: "By person" became "By user", and a name alone did not
    # say whether it belonged to a Slack member, a GitHub account or a webhook.
    snapshot = UsageProjection.page(%{})
    row = Map.merge(snapshot.totals, %{attempts: 1, requests: 1})

    users =
      for {source, actor} <- [{"slack", "U123"}, {"github", "andrew"}, {"webhook", "deploys"}],
          do: Map.merge(row, %{source: source, actor: actor, workspace: "T123"})

    html = %{snapshot | users: users} |> UsagePage.render() |> IO.iodata_to_binary()
    document = LazyHTML.from_document(html)
    assert LazyHTML.query(document, "#usage-users h2") |> LazyHTML.text() == "By user"
    refute html =~ "By person"

    sources =
      LazyHTML.query(document, "#usage-users tbody td.usage-identity .usage-secondary")
      |> Enum.map(&LazyHTML.text/1)

    assert sources == ["Slack", "GitHub", "Webhook"]

    # A Slack member reads as a person, never their ID, and "Slack" beneath
    # the name opens their profile, the way every person links to Slack
    # (Andrew, 2026-09-26). The name itself still opens their activity.
    [slack, github, _webhook] =
      document |> LazyHTML.query("#usage-users tbody td.usage-identity") |> Enum.to_list()

    refute LazyHTML.text(slack) =~ "U123"

    assert slack |> LazyHTML.query(".usage-secondary a") |> LazyHTML.attribute("href") == [
             "https://slack.com/app_redirect?team=T123&channel=U123"
           ]

    assert github |> LazyHTML.query(".usage-secondary a") |> Enum.empty?()

    # Small and grey with the place's mark, never the name's size and colour
    # (Andrew, 2026-10-03: ""slack" should not be same as large and same style
    # as username link to episodes, style them properly, you can use an icon").
    assert document |> LazyHTML.query("#usage-users .usage-source svg") |> Enum.count() == 3
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    [_, link] = Regex.run(~r/td:first-child a\.usage-source \{([^}]+)\}/, css)
    assert link =~ "font-size:13px"
    assert link =~ "color:var(--ryker-text-secondary)"
  end

  test "profile names are escaped and reported and estimated executions contribute one total" do
    snapshot = UsageProjection.page(%{})

    row =
      Map.merge(snapshot.totals, %{
        attempts: 2,
        requests: 1,
        usage_measured: 1,
        provider: "codex",
        profile: "<script>profile</script>",
        models: [],
        costed: 1,
        cost_usd: Decimal.new("1.00"),
        estimated: 1,
        estimated_cost_usd: Decimal.new("0.25")
      })

    html = %{snapshot | profiles: [row]} |> UsagePage.render() |> IO.iodata_to_binary()
    assert html =~ "&lt;script&gt;profile&lt;/script&gt;"
    refute html =~ "<script>profile</script>"
    assert html =~ "$1.25"
    refute html =~ "reported +"
    refute html =~ "≈ $"
  end

  test "unmeasured groups are not presented as zero tokens and tiny timing shares remain visible" do
    snapshot = UsageProjection.page(%{})

    row =
      Map.merge(snapshot.totals, %{attempts: 1, provider: "codex", profile: "emisar", models: []})

    totals =
      Map.merge(snapshot.totals, %{
        tokens: 100,
        provider_ms: 100_000,
        host_ms: 1,
        queued_ms: 100,
        timed: 1
      })

    html =
      %{snapshot | profiles: [row], totals: totals} |> UsagePage.render() |> IO.iodata_to_binary()

    assert html =~ "— tokens"
    assert html =~ "— of tokens"
    assert html =~ "Not measured"
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

    users =
      Enum.map(
        [{"github", "andrew"}, {"slack", "U123"}],
        fn {source, actor} ->
          Map.merge(row, %{source: source, actor: actor, workspace: "T123"})
        end
      )

    html =
      %{snapshot | totals: row, kinds: kinds, users: users}
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
          "andrew",
          "$0.0012",
          "1.2M",
          "1h"
        ] do
      assert html =~ label
    end
  end

  test "learning executions are a named work type that opens the memory page" do
    # The background memory learner spends tokens on every batch it judges, and
    # an unnamed work type sent operators to an episode list that can never hold
    # a learning turn.
    snapshot = UsageProjection.page(%{})

    row =
      Map.merge(snapshot.totals, %{
        attempts: 1,
        requests: 1,
        usage_measured: 1,
        tokens: 5_640,
        input_tokens: 4_100,
        cached_input_tokens: 900,
        output_tokens: 640,
        reasoning_tokens: 120,
        provider_ms: 7_500,
        average_provider_ms: 7_500,
        timed: 1
      })

    kinds = [Map.put(row, :work_kind, "learning")]

    performance = [
      Map.merge(row, %{
        work_kind: "learning",
        provider: "codex",
        model: "gpt-5.6-luna",
        effort: "low",
        corrections: 0,
        unsuccessful: 0
      })
    ]

    html =
      %{snapshot | totals: row, kinds: kinds, performance: performance}
      |> UsagePage.render()
      |> IO.iodata_to_binary()

    assert html =~ "Learning"
    refute html =~ "without a saved work type"
    document = LazyHTML.from_document(html)

    assert LazyHTML.query(document, "#usage-work-types a") |> LazyHTML.attribute("href") ==
             ["/memory/learning"]

    assert LazyHTML.query(document, "#model-performance tbody a") |> LazyHTML.attribute("href") ==
             ["/memory/learning"]
  end

  # Self-analysis asks the learning models once per request people were
  # unhappy with; its spend reads as a work type of its own, never as
  # unclassified work, and opens the page that lists what it analyzed.
  test "self-analysis spend reads as its own work type and opens What to fix" do
    execution!("improvement", [])

    snapshot = UsageProjection.page(%{})
    assert [%{work_kind: "self_analysis", attempts: 1}] = snapshot.kinds

    document = snapshot |> UsagePage.render() |> IO.iodata_to_binary() |> LazyHTML.from_document()
    assert document |> LazyHTML.query("#usage-work-types") |> LazyHTML.text() =~ "Self-analysis"

    assert LazyHTML.query(document, "#usage-work-types a") |> LazyHTML.attribute("href") ==
             ["/feedback/fix"]
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

    document =
      UsageProjection.page(%{})
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    counted =
      for row <- LazyHTML.query(document, ".usage-breakdown tbody tr"),
          [href] = row |> LazyHTML.query("td.usage-identity > a") |> LazyHTML.attribute("href"),
          String.starts_with?(href, "/activity?") do
        count = row |> LazyHTML.query("td:nth-child(2) strong") |> LazyHTML.text()
        name = row |> LazyHTML.query("td.usage-identity > a") |> LazyHTML.text()
        listed = Activity.list(URI.decode_query(URI.parse(href).query)).total

        assert String.to_integer(count) == listed,
               "#{name} says #{count} and opens #{href}, which lists #{listed}"

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

    document =
      %{snapshot | kinds: kinds}
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    usage =
      document
      |> LazyHTML.query("#usage-work-types tbody td:nth-child(2)")
      |> Enum.map(fn cell ->
        cell
        |> LazyHTML.to_html()
        |> String.replace(~r/<[^>]+>/, " ")
        |> String.split()
        |> Enum.join(" ")
      end)

    assert [learning, schedule] = usage
    assert learning =~ ~r/^16 executions\b/
    refute learning =~ "request"
    assert schedule =~ ~r/^1 request\b/
    refute Enum.any?(usage, &(&1 =~ "episode"))

    assert document |> LazyHTML.query(".usage-headlines") |> LazyHTML.text() =~ "Requests"
    refute document |> LazyHTML.query(".usage-summary") |> LazyHTML.text() =~ "Episodes"
  end

  test "a breakdown that leaves out Chat never says there was no activity" do
    # QA, 2026-09-25: "By channel 0" and "By user 0" each said "No activity in
    # this period" beside $2.15 of work, all of it from Chat, which neither
    # breakdown lists by design.
    execution!("admission",
      transport: "control_plane",
      conversation_ref: "control-plane:lab:" <> Ecto.UUID.generate()
    )

    document =
      UsageProjection.page(%{})
      |> UsagePage.render()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    refute LazyHTML.text(document) =~ "No activity in this period"

    assert document |> LazyHTML.query("#usage-channels .kit-empty") |> LazyHTML.text() =~
             "Chat is not listed by channel"

    assert document |> LazyHTML.query("#usage-users .kit-empty") |> LazyHTML.text() =~
             "Chat is not listed by user"
  end

  test "a chart or table wider than a phone shows that it scrolls" do
    # QA, 2026-09-25, at 390px: the token chart and every breakdown table were
    # cut at the screen edge with nothing saying they scroll sideways. Each
    # scrolling part now shades the side that has more, and only that side.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    for part <- [".chart-scroll", ".table-wrap"] do
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
