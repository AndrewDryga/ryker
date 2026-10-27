defmodule Ryker.ControlPlane.ExecutionCardDesignTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Assets, Components}

  test "inline command output stays bounded and scrollable without another disclosure" do
    # Removing the output disclosure also removed its inherited styles: a
    # retained command's output grew to 5,779px instead of scrolling inside it.
    stylesheet = File.read!("priv/static/workspace.css")
    [_, output] = Regex.run(~r/\n\.action-command-output pre\s*\{([^}]+)\}/, stylesheet)
    assert output =~ "max-height:min(24rem, 50vh)"
    assert output =~ "overflow:auto"
    assert output =~ "overscroll-behavior:contain"
  end

  test "command and inline output share readable typography and padding" do
    # The same console displayed an 11.7px command beside 14px unpadded output.
    stylesheet = File.read!("priv/static/workspace.css")
    assert [_, text] = Regex.run(~r/\n\.action-console pre\s*\{([^}]+)\}/, stylesheet)
    assert text =~ "font:13px/20px var(--ryker-font-mono)"
    assert text =~ "padding:12px 16px"
    assert text =~ "white-space:pre-wrap"
    assert text =~ "overflow-wrap:anywhere"
    assert text =~ "max-width:100%"
    assert stylesheet =~ ~r/\.action-console pre code\s*\{[^}]*font:inherit/
  end

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
      conn =
        Assets.call(
          Plug.Test.conn(
            :get,
            String.replace_prefix(Assets.path("platforms/#{service}.svg"), "/assets", "")
          ),
          []
        )

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
    document = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(document, ".routing-outcome .outcome-glyph svg path")) == 1

    assert LazyHTML.query(document, ".outcome-copy > h4") |> LazyHTML.text() |> String.trim() ==
             "Answer now"

    refute html =~ "data-copy"
    refute html =~ "<h3"
  end

  test "participation preserves the approved icon and adjacent decision-reason composition" do
    # The production rollout replaced the approved panel with an arrow, divider
    # and redundant Reason label. Preserve the preview's actual anatomy.
    for quiet <- [false, true] do
      document =
        render_component(&Components.outcome/1,
          kind: :participation,
          quiet: quiet,
          decision: "Recorded decision",
          reason: "Recorded explanation"
        )
        |> LazyHTML.from_fragment()

      assert LazyHTML.attribute(
               LazyHTML.query(document, ".participation-outcome"),
               "data-response"
             ) ==
               [if(quiet, do: "quiet", else: "respond")]

      assert Enum.count(LazyHTML.query(document, ".outcome-glyph[aria-hidden=true] svg")) == 1

      assert LazyHTML.query(document, ".outcome-glyph svg path")
             |> LazyHTML.attribute("d")
             |> hd() ==
               "M15 4H5a2 2 0 0 0-2 2v7a2 2 0 0 0 2 2h1v3l4-3h5a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2Z"

      assert LazyHTML.query(document, ".outcome-copy > h5.outcome-decision")
             |> LazyHTML.text()
             |> String.trim() ==
               "Recorded decision"

      assert LazyHTML.query(document, ".outcome-copy .outcome-reason") |> LazyHTML.text() ==
               "Recorded explanation"

      assert Enum.empty?(LazyHTML.query(document, ".outcome-reason-label"))
    end
  end

  test "outcome styling retains the approved participation geometry and quiet state" do
    css = File.read!("priv/static/workspace.css")
    assert css =~ ~r/\.participation-outcome \{[^}]*grid-template-columns:32px minmax\(0,1fr\)/

    assert css =~
             ~r/\.participation-outcome \{[^}]*background:var\(--ryker-participation-surface\)/

    assert css =~ ~r/\.participation-outcome \.outcome-glyph \{[^}]*border-radius:50%/

    assert css =~
             ~r/\.participation-outcome\[data-response=quiet\] \{[^}]*background:var\(--ryker-outcome-quiet-surface\)/

    assert css =~ "@container(max-width:420px)"
    refute css =~ ~r/\.outcome-reason[^\{]*\{[^}]*border-top:/
  end

  test "standing rules retain the approved readable ledger instead of nested detail controls" do
    css = File.read!("priv/static/workspace.css")
    assert css =~ ~r/\.standing-rule-list \{[^}]*padding:0 16px/
    assert css =~ ~s(grid-template-areas:"name details verdict" ". reason ." ". link .")
    assert css =~ ~r/\.standing-rule-definition \{[^}]*grid-area:details/
    refute css =~ ".standing-rule-definition > summary"
    refute css =~ ".standing-rule, .standing-rule.verdict-matched { padding:10px 12px; }"

    refute css =~
             ".ryker-app .standing-rule .ui-facts > div { grid-template-columns:minmax(0,1fr); gap:0; }"

    # Phone page-wide facts must not override the ledger before its own 420px
    # container breakpoint; that old cascade shifted rows at intermediate widths.
    assert :binary.match(css, ".standing-rule-list {") >
             :binary.match(css, "@media (max-width:580px)")
  end

  test "narrow routing reasons use the full approved panel width" do
    css = File.read!("priv/static/workspace.css")
    assert css =~ ".routing-outcome .outcome-copy { display:contents; }"
    assert css =~ ".routing-outcome .outcome-rationale { grid-column:1 / -1; margin:0; }"
    assert css =~ ".routing-outcome .outcome-glyph { width:20px; }"
  end
end
