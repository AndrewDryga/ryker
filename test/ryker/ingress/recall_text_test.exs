defmodule Ryker.Ingress.RecallTextTest do
  use ExUnit.Case, async: true
  alias Ryker.Ingress.RecallText

  test "attachment and block text participate even when a top-level message is empty" do
    [source | _] =
      File.read!("testdata/learning/retained-haproxy-lifecycle.json")
      |> Jason.decode!()
      |> Map.fetch!("inputs")

    text = RecallText.from(source["content"])
    assert text =~ "Host OOM kills"
    assert text =~ "website/haproxy-edge"
    refute text =~ "\"attachments\""

    assert RecallText.from(%{
             "text" => "",
             "blocks" => [%{"text" => %{"text" => "A retained decision"}}]
           }) == "A retained decision"
  end

  # Routing's earlier messages, digests and searches read a person's Slack
  # message this way. The first message of Andrew's #test thread went to
  # routing on 2026-09-28 as "<@U0C1LCVNF52> check health of our infra\n
  # check health of our infra": its text, then every "text" inside the rich
  # text blocks Slack sends beside it with the same words.
  test "a person's Slack message is searched and recalled once, as its text" do
    retained =
      "testdata/slack/retained-messages-2026-09-27.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("messages")

    assert RecallText.from(retained["check_health"]["content"]) ==
             "<@U0C1LCVNF52> check health of our infra"

    livebook = retained["livebook_parked"]["content"]
    assert RecallText.from(livebook) == livebook["text"]
  end

  test "search extraction is bounded and never rewrites the original source" do
    content = %{
      "text" => String.duplicate("é", 20_000),
      "attachments" => [%{"title" => "Still searchable", "text" => "The useful attachment"}]
    }

    assert RecallText.from(content) =~ "Still searchable"
    assert RecallText.from(content) =~ "The useful attachment"
    assert String.valid?(RecallText.from(content))
    assert String.length(RecallText.from(content)) < 1000
    assert String.length(content["text"]) == 20_000
    assert RecallText.from(%{"state" => "resolved"}) == ~s({"state":"resolved"})
  end
end
