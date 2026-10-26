defmodule Ryker.Slack.MonitoringTest do
  use ExUnit.Case, async: true
  alias Ryker.Slack.{Monitoring, Renderer}

  @captured Jason.decode!(File.read!("testdata/slack/quiet-followups.json"))

  # Three successful quiet follow-ups left the original Slack footer promising
  # a check hours in the past (2026-10-26). A timer firing isn't a completed check.
  test "quiet follow-ups count only accepted results in the original wait's chain" do
    assert Monitoring.project(@captured["wait_ref"], @captured["events"]) == %{
             "checks" => 3,
             "last_check_at" => "2026-10-26T18:46:19.501343Z",
             "state" => "waiting",
             "owner_ref" => "record:event_wait:fourth"
           }

    assert Monitoring.project(@captured["wait_ref"], Enum.take(@captured["events"], 5)) == %{
             "checks" => 2,
             "last_check_at" => "2026-10-26T17:45:55.810401Z",
             "state" => "checking",
             "owner_ref" => "turn:followup:3"
           }

    unrelated = put_in(hd(@captured["events"]), ["payload", "expected_wait", "ref"], "other")

    assert Monitoring.project(@captured["wait_ref"], [unrelated | tl(@captured["events"])]) == %{
             "checks" => 0,
             "last_check_at" => nil,
             "state" => "waiting",
             "owner_ref" => @captured["wait_ref"]
           }
  end

  test "a prepared follow-up advances only when that exact reply is confirmed delivered" do
    [resumed, accepted | _] = @captured["events"]
    accepted = put_in(accepted, ["payload", "delivery"], "reply")
    accepted = put_in(accepted, ["payload", "delivery_ref"], "delivery:followup")

    sent = %{
      "kind" => "delivery_confirmed",
      "payload" => %{"expected_delivery_ref" => "delivery:followup"}
    }

    other = put_in(sent, ["payload", "expected_delivery_ref"], "delivery:other")

    assert Monitoring.project(@captured["wait_ref"], [resumed, accepted, other])["state"] ==
             "reply"

    assert Monitoring.project(@captured["wait_ref"], [resumed, accepted, sent]) == %{
             "checks" => 1,
             "last_check_at" => "2026-10-26T16:45:32.813933Z",
             "state" => "replied",
             "owner_ref" => nil
           }
  end

  test "the live footer replaces a consumed wait without rewriting the answer or leaking audit prose" do
    record = wait_record()

    status = %{
      "checks" => 3,
      "last_check_at" => "2026-10-26T18:46:19.501343Z",
      "state" => "waiting",
      "next_check_at" => "2026-10-26T19:45:58.737263Z",
      "history_url" => "https://example.invalid/timeline/55d09539-1394-4ede-95f1-4f5bcb82c5e1"
    }

    record = Map.put(record, "presentation", %{"monitoring" => status})

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Original answer.", "records" => [record]})

    assert [answer, footer] = rendered["blocks"]
    assert answer["text"] == "Original answer."
    text = hd(footer["elements"])["text"]
    assert text =~ "3 checks completed"
    assert text =~ "No new reply needed"
    assert text =~ "Next check <!date^"
    assert text =~ "View checks"
    refute text =~ "Watching until"
    assert rendered["text"] =~ "3 checks completed"
    refute inspect(rendered) =~ "decision_reason"

    for state <- ~w(failed cancelled ended stopped reply replied checking) do
      changed =
        put_in(record, ["presentation", "monitoring"], %{
          status
          | "state" => state,
            "next_check_at" => nil
        })

      assert {:ok, result} =
               Renderer.render(%{"message" => "Original answer.", "records" => [changed]})

      refute inspect(result) =~ "Next check"
      refute inspect(result) =~ "No new reply needed"
      if state == "failed", do: assert(inspect(result) =~ "Couldn't complete the latest check")
    end
  end

  defp wait_record do
    %{
      "kind" => "event_wait",
      "ref" => "record:event_wait:initial",
      "status" => "answered",
      "payload" => %{
        "deadline_at" => "2026-10-26T18:15:00.000000Z",
        "event_matcher" => %{
          "type" => "after",
          "delay" => "30m",
          "on_timeout" => "Report what is known."
        },
        "kind" => "backup_progress",
        "verification" => "Check the replacement backup."
      }
    }
  end
end
