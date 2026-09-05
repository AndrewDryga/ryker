defmodule Responder.ControlPlane.UsagePageTest do
  use Responder.DataCase, async: false
  alias Responder.ControlPlane.{HTML, Projection}

  test "usage leads with operator metrics and ends with optional methodology" do
    html = Projection.usage(%{}) |> HTML.usage() |> IO.iodata_to_binary()

    for label <- [
          "Episodes",
          "Total tokens",
          "Fresh input",
          "Cached input",
          "Output",
          "Reasoning",
          "Cache hit rate",
          "Profiles",
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
    assert html =~ "id=\"cost-method\""
    assert String.ends_with?(html, "</details></div>")
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
        [{"control_plane", "local-operator"}, {"github", "andrew"}, {"slack", "U123"}],
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
          "Conversation Lab",
          "andrew",
          "$0.0012",
          "1.2M",
          "1h"
        ] do
      assert html =~ label
    end
  end
end
