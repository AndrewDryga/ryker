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
