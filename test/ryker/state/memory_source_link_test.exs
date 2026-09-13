defmodule Ryker.State.MemorySourceLinkTest do
  use ExUnit.Case, async: true
  alias Ryker.Slack.SourceRef
  alias Ryker.State.{ConversationObservation, MemorySourceLink, Observations}

  test "retained replies expand inside their known thread with their exact original anchor" do
    note = %ConversationObservation{
      id: "source-link-test",
      transport: "slack",
      conversation_ref: "slack:T123:C456",
      source_message_ref: "1789058455.189229",
      thread_ref: "1789058307.523479",
      occurred_at: ~U[2026-09-10 16:40:55Z],
      note: %{}
    }

    link = Observations.document(note)["source_read"]

    assert link == %{
             "tool" => "read_slack_source",
             "arguments" => %{
               "source_ref" => SourceRef.thread("T123", "C456", "1789058307.523479"),
               "anchor_ref" => SourceRef.message("T123", "C456", "1789058455.189229"),
               "view" => "thread",
               "limit" => 20
             }
           }
  end

  test "an unknown thread remains a message source rather than an invented root" do
    link = MemorySourceLink.message("slack", "slack:T123:C456", "1789058455.189229", nil)
    assert link["arguments"]["view"] == "surrounding"
    refute Map.has_key?(link["arguments"], "anchor_ref")
    assert MemorySourceLink.message("github", "slack:T123:C456", "1789058455.189229", nil) == nil
  end

  test "Lab memory expands only through the caller's exact local conversation" do
    conversation = "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    link =
      MemorySourceLink.message(
        "control_plane",
        conversation,
        "admit_input:retained",
        conversation
      )

    assert link["arguments"]["source_ref"] == conversation
    assert link["arguments"]["anchor_ref"] == "admit_input:retained"
    assert link["arguments"]["view"] == "thread"
    document = %{"source_read" => link}

    binding = %{
      episode: %{
        destination_transport: "control_plane",
        destination_conversation_ref: conversation
      },
      source_tools: ["read_slack_source"]
    }

    assert MemorySourceLink.for_caller(document, binding) == document

    assert MemorySourceLink.context_targets(%{
             "conversation_ref" => conversation,
             "source_reads" => [link]
           }) == [
             %{
               "conversation_ref" => conversation,
               "thread_ref" => conversation,
               "message_ref" => "admit_input:retained"
             }
           ]

    crossed = put_in(binding.episode.destination_conversation_ref, conversation <> "-other")
    assert MemorySourceLink.for_caller(document, crossed)["source_read"] == nil
  end

  test "a repository rollup uses its verified originals without inventing a containing thread" do
    read =
      MemorySourceLink.message(
        "slack",
        "slack:T123:C456",
        "1789058455.189229",
        "1789058307.523479"
      )

    rollup = %{
      "source_ref" => "continuity-rollup:fixture",
      "scope_kind" => "repository",
      "scope_ref" => "emisar",
      "workspace_ref" => "slack:T123",
      "source_reads" => [read]
    }

    assert [%{"conversation_ref" => "slack:T123:C456", "thread_ref" => "1789058307.523479"}] =
             MemorySourceLink.context_targets(rollup)

    refute Map.has_key?(rollup, "thread_ref")
  end

  test "a compacted Lab rollup keeps the local originals its summary already had" do
    # Retention compacts a Lab summary into a rollup whose workspace is the Lab
    # conversation, not a Slack workspace. The rollup clause only understood
    # "slack:", so the same descriptors the caller could follow a moment earlier
    # produced no targets and related memory was reported unavailable.
    conversation = "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    read =
      MemorySourceLink.message(
        "control_plane",
        conversation,
        "admit_input:retained",
        conversation
      )

    summary = %{"conversation_ref" => conversation, "source_reads" => [read]}

    rollup = %{
      "source_ref" => "continuity-rollup:fixture",
      "scope_kind" => "conversation",
      "scope_ref" => conversation,
      "workspace_ref" => conversation,
      "source_reads" => [read]
    }

    assert MemorySourceLink.context_targets(rollup) == [
             %{
               "conversation_ref" => conversation,
               "thread_ref" => conversation,
               "message_ref" => "admit_input:retained"
             }
           ]

    assert MemorySourceLink.context_targets(rollup) == MemorySourceLink.context_targets(summary)
  end

  test "a rollup cannot turn another transport's originals into local Lab targets" do
    conversation = "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"

    slack_read =
      MemorySourceLink.message(
        "slack",
        "slack:T123:C456",
        "1789058455.189229",
        "1789058307.523479"
      )

    lab_rollup = %{
      "source_ref" => "continuity-rollup:fixture",
      "scope_kind" => "conversation",
      "scope_ref" => conversation,
      "workspace_ref" => conversation,
      "source_reads" => [slack_read]
    }

    assert MemorySourceLink.context_targets(lab_rollup) == []

    github_rollup = %{
      "source_ref" => "continuity-rollup:fixture",
      "scope_kind" => "conversation",
      "scope_ref" => "github:binding:issue:7",
      "workspace_ref" => "github:binding",
      "source_reads" => [slack_read]
    }

    assert MemorySourceLink.context_targets(github_rollup) == []
  end
end
