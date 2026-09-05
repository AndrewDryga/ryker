defmodule Responder.ControlPlane.UsagePageTest do
  use Responder.DataCase, async: false
  alias Responder.ControlPlane.{HTML, Projection}

  test "usage shows all work by default without an execution ledger or generic methodology" do
    html = Projection.usage(%{}) |> HTML.usage() |> IO.iodata_to_binary()

    for label <- [
          "Episodes",
          "Total tokens",
          "Fresh input",
          "Cached input",
          "Output",
          "Reasoning",
          "Cache hit rate",
          "By profile",
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
    refute html =~ "UTC · empty days"
    refute html =~ "id=\"cost-method\""
    refute html =~ "Individual executions"
    refute html =~ "Execution ledger"
    refute html =~ "Each execution contributes one cost"
    refute html =~ "Dates use UTC"
    assert html =~ "Evaluations"
    document = LazyHTML.from_document(html)

    assert document |> LazyHTML.query(".usage-scope [aria-current=page]") |> LazyHTML.text() ==
             "All work"
  end

  test "model and effort form one readable label and average model time is explicit" do
    # Operators read 1.3m as a token count; the duration must name what it measures.
    snapshot = Projection.usage(%{})

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

    html = %{snapshot | models: [model]} |> HTML.usage() |> IO.iodata_to_binary()
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
  end

  test "estimate rates do not repeat spend totals already shown in the usage breakdowns" do
    snapshot = Projection.usage(%{})

    totals =
      Map.merge(snapshot.totals, %{
        attempts: 3,
        usage_measured: 3,
        estimated: 2,
        estimated_cost_usd: Decimal.new("1.25"),
        costed: 1,
        cost_usd: Decimal.new("0.50")
      })

    models =
      Enum.map(~w(medium high), fn effort ->
        Map.merge(totals, %{provider: "codex", model: "gpt-5.6-sol", effort: effort})
      end)

    document =
      %{snapshot | totals: totals, models: models}
      |> HTML.usage()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_document()

    pricing = LazyHTML.query(document, "#cost-method")
    assert LazyHTML.text(pricing) =~ "Rates used for estimates"
    refute LazyHTML.text(pricing) =~ "$1.25"
    refute LazyHTML.text(pricing) =~ "$0.50"
    refute LazyHTML.text(pricing) =~ "executions"
    assert length(LazyHTML.query(pricing, "tbody tr") |> LazyHTML.to_tree()) == 1

    assert LazyHTML.query(pricing, "tbody td")
           |> LazyHTML.to_tree()
           |> Enum.map(fn node -> LazyHTML.from_tree([node]) |> LazyHTML.text() end) == [
             "gpt-5.6-sol",
             "$4",
             "$0.40",
             "$20"
           ]

    assert LazyHTML.query(document, ".usage-summary .usage-cost") |> LazyHTML.text() =~ "$1.75"

    assert LazyHTML.query(document, ".usage-page > .usage-metadata-gap") |> LazyHTML.to_tree() ==
             []
  end

  test "missing reports link to affected requests instead of inventing an unknown model" do
    # Four historical failures appeared as a model row with no useful measurements.
    snapshot = Projection.usage(%{})
    totals = %{snapshot.totals | attempts: 4}
    model = Map.merge(totals, %{model: nil, effort: nil, provider: "unrecorded"})
    html = %{snapshot | totals: totals, models: [model]} |> HTML.usage() |> IO.iodata_to_binary()
    document = LazyHTML.from_document(html)
    assert html =~ "4 executions have no token report"
    assert html =~ "usage_measurement=missing"
    assert html =~ "mode=all"
    assert html =~ "4 executions without a saved model"
    refute html =~ "Unknown model"
    assert LazyHTML.query(document, "#usage-models tbody tr") |> LazyHTML.to_tree() == []
  end

  test "profiles are flat and missing metadata is not presented as a profile or work type" do
    # Old runs created fake profiles and work types that could not explain any activity.
    snapshot = Projection.usage(%{})
    row = Map.merge(snapshot.totals, %{attempts: 4, episodes: 2})

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
      |> HTML.usage()
      |> IO.iodata_to_binary()

    document = LazyHTML.from_document(html)

    assert length(LazyHTML.query(document, "#usage-profiles tbody > tr") |> LazyHTML.to_tree()) ==
             1

    assert LazyHTML.query(document, "#usage-profiles details") |> LazyHTML.to_tree() == []
    refute html =~ "Unattributed profile"
    refute html =~ "Unclassified work"
    assert html =~ "4 executions without a saved profile"
    assert html =~ "4 executions without a saved work type"
    assert LazyHTML.query(document, "#usage-work-types tbody tr") |> LazyHTML.to_tree() == []
  end

  test "people focus on episodes tokens and cost instead of provider internals" do
    snapshot = Projection.usage(%{})

    person =
      Map.merge(snapshot.totals, %{
        attempts: 2,
        episodes: 1,
        actor: "andrew",
        source: "github",
        workspace: "emisar"
      })

    html = %{snapshot | users: [person]} |> HTML.usage() |> IO.iodata_to_binary()
    document = LazyHTML.from_document(html)
    headers = document |> LazyHTML.query("#usage-people th") |> LazyHTML.to_tree()

    assert Enum.map(headers, fn node -> LazyHTML.from_tree([node]) |> LazyHTML.text() end) == [
             "Person",
             "Episodes",
             "Tokens",
             "Cost"
           ]

    assert document |> LazyHTML.query("#usage-people tbody tr") |> LazyHTML.text() =~ "andrew"
    refute document |> LazyHTML.query("#usage-people") |> LazyHTML.text() =~ "reasoning"
  end

  test "profile names are escaped and reported and estimated executions contribute one total" do
    snapshot = Projection.usage(%{})

    row =
      Map.merge(snapshot.totals, %{
        attempts: 2,
        episodes: 1,
        usage_measured: 1,
        provider: "codex",
        profile: "<script>profile</script>",
        models: [],
        costed: 1,
        cost_usd: Decimal.new("1.00"),
        estimated: 1,
        estimated_cost_usd: Decimal.new("0.25")
      })

    html = %{snapshot | profiles: [row]} |> HTML.usage() |> IO.iodata_to_binary()
    assert html =~ "&lt;script&gt;profile&lt;/script&gt;"
    refute html =~ "<script>profile</script>"
    assert html =~ "$1.25"
    refute html =~ "reported +"
    refute html =~ "≈ $"
  end

  test "unmeasured groups are not presented as zero tokens and tiny timing shares remain visible" do
    snapshot = Projection.usage(%{})

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

    html = %{snapshot | profiles: [row], totals: totals} |> HTML.usage() |> IO.iodata_to_binary()
    assert html =~ "— tokens"
    assert html =~ "— of tokens"
    assert html =~ "Not measured"
    assert html =~ "<0.1%" or html =~ "&lt;0.1%"
    assert html =~ "Time spent in queue, execution and host processing"
  end

  test "work types people and sub-cent costs remain useful in populated breakdowns" do
    snapshot = Projection.usage(%{})

    row =
      Map.merge(snapshot.totals, %{
        attempts: 1,
        episodes: 1,
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

    kinds = Enum.map(~w(conversational standard deep unclassified), &Map.put(row, :work_kind, &1))

    users =
      Enum.map(
        [{"github", "andrew"}, {"slack", "U123"}],
        fn {source, actor} ->
          Map.merge(row, %{source: source, actor: actor, workspace: "T123"})
        end
      )

    html =
      %{snapshot | totals: row, kinds: kinds, users: users}
      |> HTML.usage()
      |> IO.iodata_to_binary()

    for label <- [
          "Conversation",
          "Standard work",
          "Deep work",
          "1 execution without a saved work type",
          "andrew",
          "$0.0012",
          "1.2M",
          "1h"
        ] do
      assert html =~ label
    end
  end
end
