defmodule Ryker.ControlPlane.ReadabilityTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{Assets, EpisodeTrace}

  test "secondary labels remain legible on both paper and panel surfaces" do
    # Every usage label was pale green on paper; calibration put dark headings
    # on a black banner. These actual shipped colors must not recur.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    [_, tokens] = Regex.run(~r/\.ryker-app \.page-surface \{([^}]+)\}/, css)
    [_, muted] = Regex.run(~r/--muted:\s*(var\(--ryker-[a-z-]+\))/, tokens)

    # The surfaces are Ryker roles now (priv/static/ryker-tokens.css); resolve
    # the secondary text and both light surfaces through the same file.
    ryker = Assets.call(Plug.Test.conn(:get, "/ryker-tokens.css"), []).resp_body

    resolve = fn "var(--" <> name ->
      [_, value] =
        Regex.run(~r/--#{String.trim_trailing(name, ")")}:\s*(#[0-9a-f]{6})/, ryker)

      value
    end

    muted = resolve.(muted)

    for background <- ["var(--ryker-surface-raised)", "var(--ryker-surface)"] do
      background = resolve.(background)

      assert contrast(muted, background) >= 4.5,
             "Secondary text #{muted} is unreadable on #{background}"
    end
  end

  test "configuration help keeps the approved subtitle gap and wraps at narrow widths" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    [_, help] = Regex.run(~r/\.configuration-help \{([^}]+)\}/, css)
    [_, summary] = Regex.run(~r/\.page-surface \.configuration-help > summary \{([^}]+)\}/, css)
    assert help =~ "margin-top:-16px"
    assert help =~ "max-width:76ch"
    assert summary =~ "padding:0"
    assert css =~ "@media (max-width:600px)"
    assert css =~ "overflow-wrap:anywhere"
  end

  test "prompt and action headings cannot inherit the dark application banner" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    for selector <- [".prompt-group > header", ".case-card-heading"] do
      [_, rule] = Regex.run(Regex.compile!(Regex.escape(selector) <> " \\{([^}]+)\\}"), css)
      assert rule =~ "background:transparent"
      assert rule =~ "position:static"
    end
  end

  test "conversation memory headings cannot inherit the dark application banner" do
    # Browser QA caught nearly black titles against the global header background.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    [_, header] = Regex.run(~r/\.memory-card header \{([^}]+)\}/, css)
    assert header =~ "background:transparent"
    assert header =~ "position:static"
    assert header =~ "padding:0"
    [_, footer] = Regex.run(~r/^\.memory-card footer \{([^}]+)\}/m, css)
    assert footer =~ "padding:12px 0 0"
    assert footer =~ "margin:16px 0 0"
  end

  test "prompt token counts are visible and action facts fit a narrow viewport" do
    # Desktop HTML tests missed a hidden token-count rule and an inherited
    # two-column grid that pushed a 390px viewport to 753px.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    [_, tokens] = Regex.run(~r/\.prompt-source-estimate \{([^}]+)\}/, css)
    assert tokens =~ "font-variant-numeric:tabular-nums"
    [_, facts] = Regex.run(~r/\.action-facts \{([^}]+)\}/, css)
    assert facts =~ "grid-template-columns:minmax(0,1fr)"
    [_, cards] = Regex.run(~r/\.memory-cards \{([^}]+)\}/, css)
    assert cards =~ "grid-template-columns:minmax(0,1fr)"
    [_, card] = Regex.run(~r/\.memory-card \{([^}]+)\}/, css)
    assert card =~ "overflow-wrap:anywhere"
    [_, tooltip] = Regex.run(~r/\.prompt-inspector-tooltip \{([^}]+)\}/, css)
    assert tooltip =~ "position:fixed"
    assert tooltip =~ "max-width:min(420px, calc(100vw - 24px))"
  end

  test "prompt source disclosures have a shared chevron and right metadata slot" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    assert [_, summary] = Regex.run(~r/^\.prompt-source > summary \{([^}]+)\}/m, css)
    assert summary =~ "grid-template-columns"

    assert [_, chevron] = Regex.run(~r/^\.prompt-source-chevron \{([^}]+)\}/m, css)
    refute chevron =~ "transition:transform"

    assert css =~
             "@media (prefers-reduced-motion:no-preference) { .activity-row, .app-nav a, .ui-button { transition:background-color .12s ease; } .ui-disclosure > summary .ui-icon, .prompt-source-chevron { transition:transform .12s ease; } }"

    assert [_, open_chevron] =
             Regex.run(
               ~r/^\.prompt-source\[open\] > summary \.prompt-source-chevron \{([^}]+)\}/m,
               css
             )

    assert open_chevron =~ "rotate(90deg)"

    assert [_, metadata] = Regex.run(~r/^\.prompt-source-meta \{([^}]+)\}/m, css)
    assert metadata =~ "margin-left:auto"
  end

  test "expanded request-context fields and raw prompts remain contained" do
    # A 3.4kpx source-field JSON line pushed a 390px episode page sideways, and
    # a retained raw prompt widened a 1,440px page to 1,517px. One source-card
    # boundary keeps every character available without widening the document.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    assert [_, source_body] = Regex.run(~r/^\.prompt-source-body \{([^}]+)\}/m, css)
    assert source_body =~ "min-width:0"
    assert source_body =~ "overflow-wrap:anywhere"

    assert [_, source_fields] =
             Regex.run(~r/^\.prompt-source-body pre \{([^}]+)\}/m, css)

    assert source_fields =~ "max-width:100%"
    assert source_fields =~ "box-sizing:border-box"
    assert source_fields =~ "white-space:pre-wrap"
    assert source_fields =~ "overflow-wrap:anywhere"
    assert source_fields =~ "overflow:auto"
    refute source_fields =~ "overflow:visible"
  end

  test "the open mobile workspace menu remains inside the viewport" do
    # At 390px the menu's 320px content box opened from the More trigger and
    # widened the document to 447px. Anchor it to the full mobile navigation.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    assert [_, navigation] = Regex.run(~r/^\.mobile-navigation \{([^}]+)\}/m, css)
    assert navigation =~ "position:relative"

    assert [_, manage] = Regex.run(~r/\.mobile-manage \{([^}]+)\}/, css)
    assert manage =~ "position:static"

    assert [_, menu] = Regex.run(~r/\.mobile-manage nav \{([^}]+)\}/, css)
    assert menu =~ "left:20px"
    assert menu =~ "right:20px"
    assert menu =~ "width:auto"
    assert menu =~ "box-sizing:border-box"
  end

  test "shared fact lists cannot inherit the page surface column grid" do
    # An open Input details disclosure widened the 320px episode page to
    # 396px because the generic page-surface dl columns placed fact rows
    # beside one another instead of stacking them.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    assert [_, facts] = Regex.run(~r/\.ui-facts \{([^}]+)\}/, css)
    assert facts =~ "grid-template-columns:minmax(0,1fr)"
  end

  test "candidate evidence cannot squeeze event reasons into a side column" do
    # Full-page Chromium screenshots caught unreadably narrow rejection text
    # despite a passing page-overflow check; geometry is also browser-tested.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    assert [_, rule] = Regex.run(~r/\.candidate-evidence \{([^}]+)\}/, css)
    assert rule =~ "grid-column:1 / -1"
    assert rule =~ "min-width:0"
  end

  test "timeline cards share one readable type hierarchy" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    [_, shell] = Regex.run(~r/\.case-card-heading \{([^}]+)\}/, css)
    assert shell =~ "grid-template-columns:minmax(0,1fr) auto"
    assert shell =~ "align-items:start"

    [_, heading] = Regex.run(~r/\.case-card-heading h3 \{([^}]+)\}/, css)

    assert heading =~ "font-size:16px"
    assert heading =~ "line-height:24px"
    assert heading =~ "color:var(--ink)"

    [_, metadata] = Regex.run(~r/\.case-card-heading-meta \{([^}]+)\}/, css)
    assert metadata =~ "justify-content:flex-end"
    assert metadata =~ "text-align:right"

    [_, narrow_metadata] =
      Regex.run(~r/\.case-card-heading-stack-meta \.case-card-heading-meta \{([^}]+)\}/, css)

    assert narrow_metadata =~ "justify-content:flex-start"
    assert narrow_metadata =~ "text-align:left"

    [_, message] = Regex.run(~r/\.case-message-text \{([^}]+)\}/, css)
    assert message =~ "font-size:16px"
    assert message =~ "line-height:24px"
    assert message =~ "color:var(--ink)"

    [_, summary] = Regex.run(~r/\.case-event-summary \{ (margin:[^}]+)\}/, css)
    assert summary =~ "font-size:14px"
    assert summary =~ "line-height:20px"
    assert summary =~ "color:var(--ryker-text-secondary)"
  end

  test "timeline navigation, disclosures and copy controls keep full-size targets" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    [_, jumps] = Regex.run(~r/\.timeline-jumps a \{([^}]+)\}/, css)
    assert jumps =~ "width:44px"
    assert jumps =~ "height:44px"

    [_, disclosure] = Regex.run(~r/\.ui-disclosure > summary \{([^}]+)\}/, css)
    assert disclosure =~ "min-height:44px"

    [_, copy] = Regex.run(~r/\.copy-value \{([^}]+)\}/, css)
    assert copy =~ "width:44px"
    assert copy =~ "height:44px"
  end

  test "the episode summary keeps timing together while semantic groups reflow without scrolling" do
    # The three groups must survive both a 200% zoom viewport and a 320px
    # phone without turning the summary into a horizontally scrolling table.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    assert css =~
             ".episode-metrics { display:grid; grid-template-columns:minmax(0,2fr) minmax(0,1fr) minmax(0,1fr)"

    assert css =~
             ".episode-metrics .metric-group-timing .metric-group-items { grid-template-columns:repeat(2,minmax(0,1fr)); }"

    assert css =~
             ".episode-metrics .metric-group-timing { grid-column:1 / -1; padding:0 0 16px;"

    assert css =~ ".episode-metrics { grid-template-columns:1fr; }"
    refute css =~ ".episode-metrics { overflow"
  end

  test "participation rules stay a wrapping list and matched state is not color-only" do
    # The complete inventory can be longer than 200 rows. It remains one dense
    # list at phone width and text zoom, while a written verdict accompanies
    # the Ryker mint-on-graphite treatment for every match.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    assert [_, list] = Regex.run(~r/\.standing-rule-list \{([^}]+)\}/, css)
    assert list =~ "display:grid"
    assert list =~ "gap:0"

    assert [_, rule] = Regex.run(~r/\.standing-rule \{([^}]+)\}/, css)
    assert rule =~ "min-width:0"
    assert rule =~ "overflow-wrap:anywhere"
    refute rule =~ "border-radius"

    assert [_, matched] = Regex.run(~r/\.standing-rule\.verdict-matched \{([^}]+)\}/, css)
    assert matched =~ "border-left:4px solid var(--ryker-accent)"
    assert matched =~ "background:var(--ryker-surface-inverse)"

    assert [_, verdict] = Regex.run(~r/\.standing-rule-verdict \{([^}]+)\}/, css)
    assert verdict =~ "font-weight:600"
    assert verdict =~ "text-transform:uppercase"

    assert [_, settings] = Regex.run(~r/\.participation-facts \{([^}]+)\}/, css)
    assert settings =~ "max-width:34rem"
    refute css =~ ".standing-rule-list { overflow"
  end

  test "chapters preserve late follow-ups and tied activity in execution order" do
    now = ~U[2026-09-05 12:00:00Z]

    entries =
      for {id, band} <- [
            {"input", :input},
            {"tool-9", :work},
            {"tool-10", :work},
            {"reply", :outcome},
            {"follow-up", :input},
            {"retry", :ready}
          ] do
        %{id: id, band: band, at: now, kind: if(band == :input, do: :message, else: :event)}
      end

    chapters = EpisodeTrace.chapters(entries, now)
    assert Enum.flat_map(chapters, & &1.steps) == entries
    assert Enum.map(chapters, & &1.band) == [:input, :work, :outcome, :input, :ready]
    assert Enum.at(chapters, 1).steps |> Enum.map(& &1.id) == ["tool-9", "tool-10"]
    assert Enum.at(chapters, 3).title == "Follow-up received"
    assert Enum.at(chapters, 3).conversation_turn == 2
    assert Enum.at(chapters, 4).conversation_turn == 2
    assert [%{span: nil}] = EpisodeTrace.chapters([%{band: :ready, at: nil}], nil)
  end

  test "admission and waits cannot invent a follow-up before another message arrives" do
    # Admission completion and waiting events share the input band; treating
    # every input-band chapter as a new message invented conversation parts.
    now = ~U[2026-09-05 12:00:00Z]

    entries =
      for {id, band, kind} <- [
            {"message-1", :input, :message},
            {"admission", :ready, :request},
            {"input-admitted", :input, :event},
            {"work", :work, :request},
            {"input-wait-started", :input, :event},
            {"message-2", :input, :message},
            {"wait-resumed", :input, :event}
          ],
          do: %{id: id, band: band, kind: kind, at: now}

    chapters = EpisodeTrace.chapters(entries, now)
    assert Enum.flat_map(chapters, & &1.steps) == entries
    assert Enum.count(chapters, &(&1.title == "Follow-up received")) == 1
    assert List.last(chapters).conversation_turn == 2
    assert List.first(List.last(chapters).steps).id == "message-2"

    assert Enum.map(Enum.drop(chapters, -1), & &1.conversation_turn) == [1, 1, 1, 1, 1]
  end

  test "settings feedback colours stay legible on the dark section panel" do
    # A refusal an operator cannot read is a refusal they will retry blindly.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    tokens = Assets.call(Plug.Test.conn(:get, "/ryker-tokens.css"), []).resp_body

    assert css =~ ".form-feedback-error"
    assert css =~ "color:var(--ryker-error)"

    [_, error] = Regex.run(~r/--ryker-error:(#[0-9a-f]{6})/, tokens)
    [_, panel] = Regex.run(~r/--ryker-error-soft:(#[0-9a-f]{6})/, tokens)

    assert contrast(error, panel) >= 4.5,
           "error text #{error} is unreadable on the feedback panel #{panel}"

    for selector <- [
          ".settings-row-status[data-tone=verified]",
          ".settings-row-status[data-tone=changed]",
          ".settings-row-status[data-tone=unavailable]"
        ] do
      [_, rule] = Regex.run(Regex.compile!(Regex.escape(selector) <> " \\{([^}]+)\\}"), css)
      assert rule =~ "color:var(--ryker-text-secondary)"
    end
  end

  test "icon-only controls keep a 44px hit area around their small glyph" do
    # brand/ryker: at least 44x44px for icon buttons even if the glyph is
    # small. The activity row's "Inspect" chevron was a 20x36px link beside
    # a 14px icon, the one icon-only control on the workspace under that
    # size; the close and overflow controls already met it.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    for selector <- [
          ".row-open",
          ".ryker-app .behavior-menu > summary",
          ".lab-directory.is-open .lab-directory-close"
        ] do
      [_, rule] = Regex.run(Regex.compile!(Regex.escape(selector) <> " \\{([^}]+)\\}"), css)
      assert rule =~ ~r/(min-)?width:44px/, "#{selector} is narrower than 44px"
      assert rule =~ ~r/(min-)?height:44px/, "#{selector} is shorter than 44px"
    end
  end

  defp contrast(a, b) do
    [low, high] = Enum.sort([luminance(a), luminance(b)])
    (high + 0.05) / (low + 0.05)
  end

  defp luminance("#" <> hex) do
    hex
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.map(fn digits ->
      value = String.to_integer(Enum.join(digits), 16) / 255
      if value <= 0.04045, do: value / 12.92, else: :math.pow((value + 0.055) / 1.055, 2.4)
    end)
    |> Enum.zip([0.2126, 0.7152, 0.0722])
    |> Enum.map(fn {channel, weight} -> channel * weight end)
    |> Enum.sum()
  end
end
