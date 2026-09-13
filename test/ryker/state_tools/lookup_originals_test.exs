defmodule Ryker.StateTools.LookupOriginalsTest do
  use ExUnit.Case, async: true
  alias Ryker.StateTools.LookupOriginals

  test "a metadata-only source cannot replace an available original body" do
    raw = %{
      "anchor" => %{"source_ref" => "original:1"},
      "thread_root" => %{"source_ref" => "original:1", "text" => "The original question"},
      "messages" => []
    }

    assert {:ok, result} = LookupOriginals.fit(raw, 1_024)
    assert result["thread_root"]["text"] == "The original question"
    refute result["thread_root"]["context_reference"]
  end

  test "trimming the first copy leaves a real body for any surviving reference" do
    shared = %{"source_ref" => "original:3", "text" => "Shared original"}
    before = Map.put(shared, "padding", String.duplicate("x", 2_000))

    raw = %{
      "results" => %{
        "messages" => [
          %{
            "source_ref" => "original:1",
            "content" => "First hit",
            "context_messages" => %{"before" => [before], "after" => []}
          },
          %{"source_ref" => "original:2", "content" => "Second hit", "thread_root" => shared}
        ]
      }
    }

    assert {:ok, result} = LookupOriginals.fit(raw, 1_024)
    [first, second] = result["results"]["messages"]
    assert first["context_messages"]["before"] == []
    assert second["thread_root"] == shared
  end

  test "GitHub search trims optional discussion before discarding matched subject bodies" do
    hit = %{
      "number" => 42,
      "body" => "The original request",
      "discussion_context" => %{
        "items" => [%{"id" => 1, "body" => String.duplicate("Comment ", 200)}],
        "coverage" => %{"status" => "complete"},
        "next_cursor" => nil
      },
      "source_read" => %{
        "tool" => "read_github_conversation",
        "arguments" => %{"section" => "issue_comments", "cursor" => nil, "limit" => 5}
      }
    }

    assert {:ok, result} = LookupOriginals.fit(%{"items" => [hit]}, 1_024)

    assert [%{"body" => "The original request", "discussion_context" => discussion}] =
             result["items"]

    assert discussion["items"] == []
    assert discussion["coverage"]["status"] == "partial"
  end

  test "byte-trimmed thread originals remain reachable independently of the next provider page" do
    root = "slack-source:v1:T123:C123:thread:1789000000.000001"

    ref = fn n ->
      "slack-source:v1:T123:C123:message:1789000000.#{String.pad_leading(to_string(n), 6, "0")}"
    end

    original = fn n ->
      %{
        "source_ref" => ref.(n),
        "ts" => "1789000000.#{String.pad_leading(to_string(n), 6, "0")}",
        "text" => String.duplicate("original ", 120)
      }
    end

    raw = %{
      "source_ref" => root,
      "view" => "thread",
      "cursor" => "later-page",
      "anchor" => %{"source_ref" => ref.(5), "ts" => "1789000000.000005", "text" => "Anchor"},
      "messages" => Enum.map([2, 3, 4, 6, 7, 8], original)
    }

    assert {:ok, result} = LookupOriginals.fit(raw, 4_096)
    assert result["cursor"] == "later-page"
    assert %{"before" => before, "after" => after_read} = result["omitted_context"]

    for descriptor <- [before, after_read] do
      assert descriptor["tool"] == "read_slack_source"
      assert descriptor["arguments"]["source_ref"] == root
      assert descriptor["arguments"]["view"] == "thread"
      refute descriptor["arguments"]["cursor"]

      refute Enum.any?(
               result["messages"],
               &(&1["source_ref"] == descriptor["arguments"]["anchor_ref"])
             )
    end
  end
end
