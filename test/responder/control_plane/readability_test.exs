defmodule Responder.ControlPlane.ReadabilityTest do
  use ExUnit.Case, async: true

  alias Responder.ControlPlane.{Assets, EpisodeTrace}

  test "secondary labels remain legible on both paper and panel surfaces" do
    # Every usage label was pale green on paper; calibration put dark headings
    # on a black banner. These actual shipped colors must not recur.
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body
    [_, tokens] = Regex.run(~r/\.responder-app \.legacy-surface \{([^}]+)\}/, css)
    [_, muted] = Regex.run(~r/--muted:\s*(#[0-9a-f]{6})/, tokens)

    for background <- ["#ffffff", "#f5f5f1"] do
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
