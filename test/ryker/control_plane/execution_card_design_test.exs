defmodule Ryker.ControlPlane.ExecutionCardDesignTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Assets, Components}

  test "execution cards have one reading column rather than a phantom metadata column" do
    # The first product rollout kept the old two-column event grid. New sections
    # lost 16px at their right edge, while facts and evidence spanned both columns.
    # This source contract complements real native-shell browser measurements.
    stylesheet = File.read!("priv/static/workspace.css")
    [_, event] = Regex.run(~r/\n\.case-event-content\s*\{([^}]+)\}/, stylesheet)
    assert event =~ ~r/grid-template-columns:\s*minmax\(0,\s*1fr\)\s*;/
  end

  test "repository identities and access modes remain separate readable list rows" do
    html =
      render_component(&Components.fact_list/1,
        facts: [
          %{
            label: "Repositories",
            value: "retained fallback",
            links: [
              %{
                label: "platform/gateway:main",
                href: "https://github.com/platform/gateway/tree/main",
                note: "read only"
              },
              %{label: "platform/worker:stable", href: nil, note: "may change"}
            ]
          }
        ]
      )
      |> LazyHTML.from_fragment()

    rows = LazyHTML.query(html, ".fact-links > li")
    assert Enum.count(rows) == 2
    assert LazyHTML.text(Enum.at(rows, 0)) =~ "platform/gateway:main"
    assert LazyHTML.text(Enum.at(rows, 0)) =~ "read only"
    assert LazyHTML.text(Enum.at(rows, 1)) =~ "may change"

    assert html |> LazyHTML.query("a") |> LazyHTML.attribute("href") == [
             "https://github.com/platform/gateway/tree/main"
           ]
  end

  test "card titles have one owner at the approved reading size" do
    # Dense overrides silently replaced the preview's hierarchy after the
    # first rollout. Keeping one owner prevents another late cascade patch.
    stylesheet = File.read!("priv/static/workspace.css")
    rules = Regex.scan(~r/\n\.case-card-heading h3\s*\{([^}]+)\}/, stylesheet)
    assert length(rules) == 1
    [[_, heading]] = rules
    assert heading =~ ~r/font-size:\s*18px\s*;/
  end

  test "message identity, content and details share one frame separate from the card title" do
    html =
      Components.message_block_html("Ryker", "<p>A retained reply.</p>",
        title: "Sent response",
        meta: "<time>12:00 UTC</time>",
        footer: "<details><summary>Details</summary>Receipt</details>"
      )
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert html |> LazyHTML.query(".ui-message > .ui-message-title") |> LazyHTML.text() ==
             "Sent response"

    frame = LazyHTML.query(html, ".ui-message > .ui-message-frame")
    assert frame |> LazyHTML.query(".ui-message-header strong") |> LazyHTML.text() == "Ryker"
    assert frame |> LazyHTML.query(".ui-message-body") |> LazyHTML.text() == "A retained reply."

    assert frame |> LazyHTML.query(".ui-message-footer details") |> LazyHTML.text() ==
             "DetailsReceipt"
  end

  test "card actions keep a full hit target around compact button paint" do
    stylesheet = File.read!("priv/static/workspace.css")
    assert [_, target] = Regex.run(~r/\.execution-document \.ui-button\s*\{([^}]+)\}/, stylesheet)
    assert target =~ "min-height:44px"

    assert [_, paint] =
             Regex.run(~r/\.execution-document \.ui-button::before\s*\{([^}]+)\}/, stylesheet)

    assert paint =~ "inset:6px 0"

    assert stylesheet =~
             ~r/\.execution-document \.ui-button:is\(:disabled,\.is-disabled,\[aria-disabled=true\]\)::before\s*\{[^}]*background:var\(--ryker-disabled-bg\)/

    assert stylesheet =~
             ~r/\.execution-document \.ui-button:is\(:disabled,\.is-disabled,\[aria-disabled=true\]\)\s*\{[^}]*color:var\(--ryker-disabled-text\)/
  end

  test "search result headings cannot inherit sticky page-header chrome" do
    # New per-method search receipts revealed header bars floating over the
    # results because the generic page header still owned their layout.
    stylesheet = File.read!("priv/static/workspace.css")
    [_, heading] = Regex.run(~r/\n\.search-match-heading\s*\{([^}]+)\}/, stylesheet)
    assert heading =~ "position:static"
    assert heading =~ "padding:0"
    assert heading =~ "background:transparent"
  end

  test "raw copy is the final utility in its own content block" do
    html = Components.copy_block_html("<pre>exact retained bytes</pre>") |> IO.iodata_to_binary()
    assert :binary.match(html, "</pre>") < :binary.match(html, "data-copy-block")
    assert html =~ "exact retained bytes"
  end

  test "service badges use supplied artwork beside a readable name" do
    for service <- [:emisar, :slack, :github, :ryker, :workspace] do
      html = render_component(&Components.service_badge/1, service: service)
      assert html =~ "data-service=\"#{service}\""
      assert html =~ Components.service_name(service)
      if service != :workspace, do: assert(html =~ "service-mark")
    end

    for service <- ["slack", "github"] do
      conn = Assets.call(Plug.Test.conn(:get, "/platforms/#{service}.svg"), [])
      assert conn.status == 200
      assert conn.resp_body == File.read!("site/assets/platforms/#{service}.svg")
    end
  end

  test "an outcome keeps decision and attributed reason together without large competing panels" do
    html =
      render_component(&Components.outcome/1,
        decision: "Answer now",
        reason: "A short greeting.",
        reason_label: "Model's reason"
      )

    assert html =~ "Answer now"
    assert html =~ "A short greeting."
    assert html =~ "Model&#39;s reason"
    assert html =~ "decision-outcome"
    refute html =~ "data-copy"
    refute html =~ "<h3"
  end
end
