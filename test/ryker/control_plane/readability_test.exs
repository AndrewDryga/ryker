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

  test "prompt and action headings cannot inherit the dark application banner" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    for selector <- [".prompt-group > header", ".action-card > header"] do
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
    [_, tokens] = Regex.run(~r/\.prompt-assembly \.prompt-source-state \{([^}]+)\}/, css)
    assert tokens =~ "display:inline"
    [_, facts] = Regex.run(~r/\.action-facts \{([^}]+)\}/, css)
    assert facts =~ "grid-template-columns:minmax(0,1fr)"
    [_, cards] = Regex.run(~r/\.memory-cards \{([^}]+)\}/, css)
    assert cards =~ "grid-template-columns:minmax(0,1fr)"
    [_, card] = Regex.run(~r/\.memory-card \{([^}]+)\}/, css)
    assert card =~ "overflow-wrap:anywhere"
    [_, tooltip] = Regex.run(~r/\.prompt-fragment:focus::before \{([^}]+)\}/, css)
    assert tooltip =~ "position:fixed"
    assert tooltip =~ "calc(100vw - 32px)"
  end

  test "expanded request-context source fields remain contained and readable" do
    # A 3.4kpx source-field JSON line pushed the whole episode page sideways at
    # 390px; wrapping and a bounded scroll container keep every character
    # available without widening the document.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    assert [_, source_fields] =
             Regex.run(~r/\.prompt-source-body details > pre \{([^}]+)\}/, css)

    assert source_fields =~ "max-width:100%"
    assert source_fields =~ "box-sizing:border-box"
    assert source_fields =~ "white-space:pre-wrap"
    assert source_fields =~ "overflow-wrap:anywhere"
    assert source_fields =~ "overflow:auto"
    refute source_fields =~ "overflow:visible"
  end

  test "candidate evidence cannot squeeze event reasons into a side column" do
    # Full-page Chromium screenshots caught unreadably narrow rejection text
    # despite a passing page-overflow check; geometry is also browser-tested.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    assert [_, rule] = Regex.run(~r/\.candidate-evidence \{([^}]+)\}/, css)
    assert rule =~ "grid-column:1 / -1"
    assert rule =~ "min-width:0"
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

  test "settings feedback colours stay legible on the white section panel" do
    # A refusal an operator cannot read is a refusal they will retry blindly.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    for selector <- [
          ".settings-error",
          ".settings-row-status[data-tone=verified]",
          ".settings-row-status[data-tone=changed]",
          ".settings-row-status[data-tone=unavailable]"
        ] do
      [_, rule] = Regex.run(Regex.compile!(Regex.escape(selector) <> " \\{([^}]+)\\}"), css)
      [_, colour] = Regex.run(~r/color:\s*(#[0-9a-f]{6})/, rule)

      assert contrast(colour, "#ffffff") >= 4.5,
             "#{selector} text #{colour} is unreadable on the section panel"
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
