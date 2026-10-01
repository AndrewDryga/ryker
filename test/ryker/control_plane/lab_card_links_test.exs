defmodule Ryker.ControlPlane.LabCardLinksTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.{Assets, HTML}

  @pull_request "https://github.com/AndrewDryga/test/pull/4"

  # Manual test, 2026-10-01: the card for the draft PR Ryker had just opened in Chat
  # (AndrewDryga/test#4) linked to it as "Open exact approval", the words for an Emisar approval.
  # Andrew, the same day: "open PR should be a button, first one, and it should be more prominent
  # than others since it's CTA for next step".
  test "a card's pull request is its first button, and the prominent one" do
    for kind <- ["publication_result", "task"] do
      [first | rest] = actions(card(kind, @pull_request, [timeline()]))

      assert LazyHTML.attribute(first, "class") == ["button primary"]
      assert LazyHTML.attribute(first, "href") == [@pull_request]
      assert LazyHTML.text(first) == "Open pull request"
      assert Enum.map(rest, &LazyHTML.text/1) == ["Timeline"]
    end

    [approval] =
      actions(card("emisar_approval", "https://emisar.example.invalid/approvals/1", []))

    assert LazyHTML.text(approval) == "Open exact approval"
  end

  # Andrew, 2026-10-01, of a task card's buttons: "text in some buttons still not aligned". A link
  # styled as a button kept a block box, so its words sat at the top of the button beside the
  # centred words of a form's button.
  test "a link and a form button on a card centre their words alike" do
    css = Assets.call(Plug.Test.conn(:get, "/workspace.css"), []).resp_body

    assert [_, button] =
             Regex.run(
               ~r/\.chat-message-extras button, \.chat-message-extras \.button \{([^}]+)\}/,
               css
             )

    assert button =~ "display:inline-flex"
    assert button =~ "align-items:center"
    assert button =~ "box-sizing:border-box"
  end

  defp timeline,
    do: %{choice_index: nil, method: :get, path: "/timeline/request", label: "Timeline"}

  defp card(kind, url, controls) do
    %{
      action: nil,
      choices: [],
      controls: controls,
      details: [],
      kind: kind,
      label: "Card",
      ref: "record:#{kind}",
      status: :published,
      summary: nil,
      title: "Title",
      url: url
    }
  end

  defp actions(card) do
    %{cards: [card]}
    |> HTML.lab_message_extras()
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(".lab-card-actions > a, .lab-card-actions > form > button")
    |> Enum.to_list()
  end
end
