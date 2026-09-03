defmodule Responder.Work.PromptTest do
  use ExUnit.Case, async: true

  alias Responder.Work.Prompt

  test "universal instructions require owning-tool receipts and final preflight" do
    document = Prompt.build(%{"episode_ref" => "episode-1"}) |> Jason.decode!()
    instructions = document["instructions"]

    assert instructions =~ "owning tool's receipt"
    assert instructions =~ "cite_source using the source_ref returned by that tool"
    assert instructions =~ "A source-backed final without that record_ref is incomplete"
    assert instructions =~ "planning, pending, queued, or running"
    assert instructions =~ "durable wait for the next exact lifecycle update"
    assert instructions =~ "Call validate_final"
    assert instructions =~ "exact JSON"
    assert instructions =~ "repair it in"
    assert instructions =~ "same session"
    refute instructions =~ "state_token"
    refute instructions =~ "operation_id"
  end

  test "universal instructions treat unknown authenticated payloads as bounded evidence" do
    instructions = Prompt.build(%{}) |> Jason.decode!() |> Map.fetch!("instructions")

    assert instructions =~ "arbitrary JSON"
    assert instructions =~ "without a vendor-specific schema"
    assert instructions =~ "Report the exact observed fields"
    assert String.downcase(instructions) =~ "do not\ncreate actions or durable records"
  end

  test "universal work instructions use the host-bound destination instead of assuming Slack" do
    document =
      Prompt.build(%{
        "destination" => %{"transport" => "github"},
        "offer_confirmation_supported" => false
      })
      |> Jason.decode!()

    instructions = document["instructions"]

    refute instructions =~ "working in Slack"
    assert instructions =~ "host owns destination"
    assert instructions =~ "Do not post"
    assert instructions =~ "bound conversation"
  end

  test "universal instructions explain the typed Slack entity boundary" do
    instructions = Prompt.build(%{}) |> Jason.decode!() |> Map.fetch!("instructions")

    assert instructions =~ "[@Name](slack-user:U123)"
    assert instructions =~ "[#channel](slack-channel:slack:T123:C456)"
    assert instructions =~ "slack-usergroup:S123"
    assert instructions =~ "slack-broadcast:here"
    assert instructions =~ "Never write raw Slack control syntax"
  end
end
