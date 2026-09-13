defmodule Ryker.Delivery.RequestTest do
  use ExUnit.Case, async: true

  alias Ryker.Delivery.Request

  test "prepares one immutable message or reaction without platform credentials" do
    assert {:ok, message} = Request.new(message_attributes())
    assert message.kind == :message
    assert message.document == %{"message" => "Done."}

    assert {:ok, rich_message} =
             Request.new(%{
               message_attributes()
               | document: %{
                   "message" => "I can prepare that.",
                   "records" => [
                     %{
                       "kind" => "task_offer",
                       "payload" => %{
                         "kind" => "engineering",
                         "prompt" => "Make the change.",
                         "repository" => "ryker",
                         "title" => "Make the change"
                       },
                       "ref" => "record:task_offer:1",
                       "status" => "open"
                     }
                   ]
                 }
             })

    assert hd(rich_message.document["records"])["ref"] == "record:task_offer:1"

    assert {:ok, reaction} =
             Request.new(%{
               message_attributes()
               | document: %{"emoji_name" => "eyes"},
                 kind: :reaction,
                 source_item_ref: "1787832000.000100"
             })

    assert reaction.kind == :reaction

    assert {:ok, keyword_message} = Request.new(Map.to_list(message_attributes()))
    assert keyword_message == message
  end

  test "rejects malformed destinations and delivery shapes before an adapter runs" do
    assert Request.new(Map.delete(message_attributes(), :ref)) ==
             {:error, {:invalid_delivery_request, :fields}}

    assert Request.new(:invalid) == {:error, {:invalid_delivery_request, :fields}}

    assert Request.new(Map.to_list(message_attributes()) ++ [ref: "duplicate"]) ==
             {:error, {:invalid_delivery_request, :fields}}

    assert Request.new(%{message_attributes() | transport: "Slack.Module"}) ==
             {:error, {:invalid_delivery_request, :transport}}

    assert Request.new(%{message_attributes() | document: %{"message" => " "}}) ==
             {:error, {:invalid_delivery_request, :message}}

    assert Request.new(%{
             message_attributes()
             | document: %{"message" => String.duplicate("x", 20_001)}
           }) == {:error, {:invalid_delivery_request, :message}}

    assert Request.new(%{
             message_attributes()
             | document: %{"message" => "Done.", "records" => [%{"kind" => "task_offer"}]}
           }) == {:error, {:invalid_delivery_request, :records}}

    assert Request.new(%{message_attributes() | document: %{"message" => <<255>>}}) ==
             {:error, {:invalid_delivery_request, :document}}

    assert Request.new(%{
             message_attributes()
             | document: %{"emoji_name" => "eyes"},
               kind: :reaction,
               source_item_ref: nil
           }) == {:error, {:invalid_delivery_request, :source_item_ref}}

    assert Request.new(%{
             message_attributes()
             | document: %{"emoji_name" => "eyes", "extra" => true},
               kind: :reaction,
               source_item_ref: "1787832000.000100"
           }) == {:error, {:invalid_delivery_request, :reaction}}
  end

  test "accepts only exact bounded image artifacts" do
    variants = [
      {"image/png", "chart.png", <<137, 80, 78, 71, 13, 10, 26, 10, 0>>},
      {"image/jpeg", "photo.jpg", <<255, 216, 255, 224>>},
      {"image/gif", "old.gif", "GIF87a-bytes"},
      {"image/gif", "new.gif", "GIF89a-bytes"},
      {"image/webp", "plot.webp", <<"RIFF", 0, 0, 0, 0, "WEBP", 1>>}
    ]

    artifacts =
      Enum.with_index(variants, fn {media_type, name, data}, index ->
        artifact(index, name, media_type, data)
      end)

    assert {:ok, request} = Request.new(Map.put(message_attributes(), :artifacts, artifacts))
    assert request.artifacts == artifacts

    for invalid <- [
          :invalid,
          [nil],
          [Map.put(hd(artifacts), "extra", true)],
          [%{hd(artifacts) | "bytes" => 0}],
          [%{hd(artifacts) | "name" => "../chart.png"}],
          [%{hd(artifacts) | "ref" => "bad ref"}],
          [%{hd(artifacts) | "sha256" => String.duplicate("a", 64)}],
          [%{hd(artifacts) | "media_type" => "text/plain"}],
          [hd(artifacts), hd(artifacts)],
          List.duplicate(hd(artifacts), 6),
          [
            %{hd(artifacts) | "bytes" => 4 * 1_024 * 1_024 + 1},
            %{List.last(artifacts) | "bytes" => 4 * 1_024 * 1_024 + 1}
          ]
        ] do
      assert Request.new(Map.put(message_attributes(), :artifacts, invalid)) ==
               {:error, {:invalid_delivery_request, :artifacts}}
    end

    assert Request.new(%{
             message_attributes()
             | document: %{"message" => "Done.", "unexpected" => true}
           }) == {:error, {:invalid_delivery_request, :document}}

    assert Request.new(%{
             message_attributes()
             | document: %{"emoji_name" => " "},
               kind: :reaction,
               source_item_ref: "1787832000.000100"
           }) == {:error, {:invalid_delivery_request, :emoji_name}}
  end

  defp artifact(index, name, media_type, data) do
    sha256 = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    %{
      "bytes" => byte_size(data),
      "data" => data,
      "media_type" => media_type,
      "name" => name,
      "ref" => "artifact-#{index}",
      "sha256" => sha256
    }
  end

  defp message_attributes do
    %{
      conversation_ref: "slack:T123:C456",
      document: %{"message" => "Done."},
      kind: :message,
      ref: "delivery:turn-1",
      source_item_ref: nil,
      thread_ref: "1787832000.000100",
      transport: "slack"
    }
  end
end
