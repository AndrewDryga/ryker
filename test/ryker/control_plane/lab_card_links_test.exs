defmodule Ryker.ControlPlane.LabCardLinksTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.HTML

  # Manual test, 2026-10-01: the card for the draft PR Ryker had just opened in Chat
  # (AndrewDryga/test#4) linked to it as "Open exact approval", the words for an Emisar approval.
  test "a card's pull request link says it opens the pull request" do
    pull_request =
      render(card("publication_result", "https://github.com/AndrewDryga/test/pull/4"))

    assert pull_request =~ ~s(>Open pull request</a>)
    refute pull_request =~ "Open exact approval"

    task = render(card("task", "https://github.com/AndrewDryga/test/pull/4"))
    assert task =~ ~s(>Open pull request</a>)

    approval = render(card("emisar_approval", "https://emisar.example.invalid/approvals/1"))
    assert approval =~ ~s(>Open exact approval</a>)
  end

  defp card(kind, url) do
    %{
      action: nil,
      choices: [],
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

  defp render(card), do: %{cards: [card]} |> HTML.lab_message_extras() |> IO.iodata_to_binary()
end
