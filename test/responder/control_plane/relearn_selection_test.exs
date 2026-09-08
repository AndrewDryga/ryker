defmodule Responder.ControlPlane.RelearnSelectionTest do
  use ExUnit.Case, async: false

  alias Phoenix.HTML.Safe
  alias Responder.ControlPlane.{Assets, RelearnPanel, SlackNames}

  test "every local control-plane module import has a served JavaScript asset" do
    # One missing helper makes the browser reject the whole entry module,
    # breaking the existing composer as well as source selection.
    entry = Assets.call(Plug.Test.conn(:get, "/control-plane.js"), [])
    assert entry.status == 200

    for [_, path] <- Regex.scan(~r/from "(\/assets\/[^"\s]+)"/, entry.resp_body) do
      response = Assets.call(Plug.Test.conn(:get, String.replace_prefix(path, "/assets", "")), [])
      assert response.status == 200, "missing imported asset #{path}"

      assert Plug.Conn.get_resp_header(response, "content-type") == [
               "text/javascript; charset=utf-8"
             ]
    end
  end

  test "an empty search page keeps the exact scoped form for off-page explicit selections" do
    # A correction and its original decision can live on different source pages.
    # Hiding the form on an empty search made that explicit set impossible to send.
    preview = preview()
    html = render(%{preview | entries: []})

    assert html =~ "No eligible current messages match"
    assert html =~ ~s(data-relearn-scope="knowledge:relearn:#{preview.topic_id}:3:2")
    assert html =~ "data-relearn-hidden"
    assert html =~ "data-relearn-count"
    assert html =~ "data-relearn-clear"
    assert html =~ "current page only"
    assert html =~ ~s(method="post")
  end

  test "retry selection is scoped to both the target head and lifetime budget" do
    preview = preview()
    batch = %{id: Ecto.UUID.generate(), budget_version: 4}
    html = render(%{preview | existing_batch: batch})

    assert html =~ ~s(data-relearn-scope="learning:reselect:#{batch.id}:4:3:2")
    assert html =~ "one additional model start"
    refute html =~ ~r/<input[^>]*type="checkbox"[^>]*checked/
  end

  test "each exact source tuple exposes its identity and execution mode without preselection" do
    preview = preview()
    source = hd(preview.entries)
    html = render(preview)

    assert html =~ ~s(data-relearn-source="#{source.input_id}")
    assert html =~ RelearnPanel.source_value(source)
    assert html =~ "Shadow mode"
    assert html =~ "one execution mode"
    refute html =~ "Search or change pages before making your selection"
    refute html =~ ~r/<input[^>]*type="checkbox"[^>]*checked/
  end

  test "source authors use the workspace name cache and remain redacted" do
    start_supervised!(
      {SlackNames,
       workspace: "TPICKER", fetch: fn _ -> {:ok, "Andrew <admin> password=do-not-display"} end}
    )

    SlackNames.name("TPICKER", "UAUTHOR")
    GenServer.call(SlackNames, :refresh)
    html = render(preview())

    assert html =~ "Andrew &lt;admin&gt;"
    assert html =~ "[redacted]"
    refute html =~ "do-not-display"
    refute html =~ "<span>UAUTHOR</span>"
  end

  test "rendered source Markdown does not preserve template indentation" do
    # Full message text is already rendered Markdown; pre-wrap on its container
    # added HEEx whitespace and broke the compact source picker on small screens.
    html = render(preview())
    assert html =~ ~s(class="relearn-excerpt markdown-preview)
    assert html =~ ~s(class="relearn-full-message markdown-preview")
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    refute css =~ ~r/\.relearn-(?:excerpt|full-message)\s*\{[^}]*white-space:pre-wrap/
    assert css =~ ".responder-app .relearn-selection-tools [hidden] { display:none; }"
  end

  test "a mixed-mode selection explains the correction without claiming an attempt exists" do
    message = RelearnPanel.reason(:learning_mixed_execution_modes)
    assert message =~ "live"
    assert message =~ "shadow"
    assert message =~ "same execution mode"
    refute message =~ "frozen attempt"
  end

  defp preview do
    input =
      "testdata/learning/retained-haproxy-lifecycle.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("inputs")
      |> hd()

    {:ok, at, _} = DateTime.from_iso8601(input["occurred_at"] <> "Z")

    %{
      topic_id: Ecto.UUID.generate(),
      version: 3,
      generation: 2,
      eligible?: true,
      reason: nil,
      existing_batch: nil,
      transport: "slack",
      conversation_ref: "slack:TPICKER:CPICKER",
      entries: [
        %{
          input_id: Ecto.UUID.generate(),
          revision: input["revision"],
          fingerprint: input["event_fingerprint"],
          occurred_at: at,
          actor_ref: "UAUTHOR",
          execution_mode: :shadow,
          content: input["content"],
          source_message_ref: input["source_item_ref"],
          suggested?: true
        }
      ],
      page: 1,
      pages: 2,
      total: 21,
      q: ""
    }
  end

  defp render(preview) do
    RelearnPanel.render(%{
      __changed__: nil,
      preview: preview,
      csrf_secret: String.duplicate("s", 32)
    })
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end
end
