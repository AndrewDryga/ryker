defmodule Responder.Slack.InvestigationReplyTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.{Renderer, ReplyRecords}

  @fixture Path.expand("../../../testdata/slack/terraform-deployment-reply.json", __DIR__)

  test "the recorded Terraform review keeps audit records out of the Slack reply" do
    # Seven evidence dumps, a repeated finding and private wait instructions buried the review.
    # Linkless source footers later buried it again with labels the reader could
    # not open. Evidence stays in the audit; only useful source links belong here.
    fixture = @fixture |> File.read!() |> Jason.decode!()

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => fixture["candidate"]["message"],
               "records" => fixture["records"]
             })

    assert rendered["text"] == fixture["candidate"]["message"]
    refute inspect(rendered["blocks"]) =~ "Evidence ·"
    refute inspect(rendered["blocks"]) =~ "Finding ·"
    refute inspect(rendered["blocks"]) =~ "Read tfc.run_details"
    refute inspect(rendered["blocks"]) =~ "Waiting until:"
    refute inspect(rendered["blocks"]) =~ "source link unavailable"
  end

  test "recorded sources become named links without repeating observations or findings" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    records = ReplyRecords.enrich(fixture["records"], fixture["receipts"])

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Review complete.", "records" => records})

    blocks = inspect(rendered["blocks"])

    assert blocks =~
             "https://emisar.dev/app/emisar/runs/01a085b2-310a-7f88-8b05-138e306c7555|Saved Terraform plan"

    assert blocks =~ "|Latest database backup>"
    refute blocks =~ "Source: 01a"
    refute blocks =~ "Backup completion has not yet been checked"
    assert blocks =~ "Next check <!date^"
    assert blocks =~ "Monitoring deadline <!date^"
    assert blocks =~ "2026-09-09 10:45 UTC"
    assert blocks =~ "2026-09-10 10:30 UTC"
  end

  test "superseded observations stay in the audit but do not compete in source links" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    [old, current | _] = Enum.filter(fixture["records"], &(&1["kind"] == "evidence"))
    current = put_in(current, ["payload", "supersedes"], [old["ref"]])
    records = ReplyRecords.enrich([old, current], fixture["receipts"])

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Current status.", "records" => records})

    refute inspect(rendered) =~ "|Saved Terraform plan>"
    assert inspect(rendered) =~ "|Terraform run status>"
    assert hd(records)["payload"] == old["payload"]
  end

  test "missing, ambiguous and unsafe source URLs never become invented links" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    [record | _] = fixture["records"]
    id = record["payload"]["source_id"]
    url = "https://emisar.dev/app/emisar/runs/" <> id

    for unsafe <- [
          "http://emisar.dev/runs/" <> id,
          "https://token:secret@emisar.dev/runs/" <> id,
          url <> "?token=secret",
          url <> "#private",
          "https://emisar.dev/<!channel>/runs/" <> id,
          "https://emisar.dev/%0A/runs/" <> id,
          "https://emisar.dev/%7C/runs/" <> id
        ] do
      refute ReplyRecords.safe_url?(unsafe)
      [projected] = ReplyRecords.enrich([record], [%{"run_id" => id, "run_url" => unsafe}])
      refute Map.has_key?(projected, "presentation")
    end

    [projected] =
      ReplyRecords.enrich([record], [
        %{"run_id" => id, "run_url" => url},
        %{"run_id" => id, "run_url" => "https://another.example/runs/" <> id}
      ])

    refute Map.has_key?(projected, "presentation")

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Partial review.", "records" => [projected]})

    refute inspect(rendered) =~ "Sources"
    refute inspect(rendered) =~ "source link unavailable"
    refute inspect(rendered) =~ "01a085b2-310a-7f88-8b05-138e306c7555"
  end

  test "the renderer links the resolved source, never the record's own source_id" do
    # The footer had its own URL policy and fell back to payload source_id, so a
    # model-written URL stayed clickable even after the host refused to resolve it.
    # Two consumers of one link must not disagree about what proved it.
    fixture = @fixture |> File.read!() |> Jason.decode!()
    [record | _] = fixture["records"]
    claimed = "https://emisar.dev/app/emisar/runs/" <> record["payload"]["source_id"]
    record = put_in(record, ["payload", "source_id"], claimed)

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Review complete.", "records" => [record]})

    refute inspect(rendered) =~ "Sources"
    refute inspect(rendered) =~ claimed
  end

  test "a mixed source footer keeps real links and omits linkless audit labels" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    records = ReplyRecords.enrich(fixture["records"], fixture["receipts"])
    [first | _] = records
    original_payload = first["payload"]
    linkless = Map.delete(first, "presentation")

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "Review complete.",
               "records" => [linkless | tl(records)]
             })

    blocks = inspect(rendered["blocks"])
    assert blocks =~ "Sources"
    assert blocks =~ "|Latest database backup>"
    refute blocks =~ "Saved Terraform plan"
    refute blocks =~ "source link unavailable"
    assert linkless["payload"] == original_payload
  end

  test "repeated evidence for the same source produces one navigable link" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    [record | _] = ReplyRecords.enrich(fixture["records"], fixture["receipts"])
    duplicate = Map.put(record, "ref", "record:evidence:same-source")

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Review.", "records" => [record, duplicate]})

    assert length(Regex.scan(~r/\|Saved Terraform plan>/, inspect(rendered["blocks"]))) == 1
  end

  test "source labels cannot turn source links into Slack notifications" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    [record | _] = fixture["records"]
    record = put_in(record, ["payload", "target"], "Plan | <!channel>")
    records = ReplyRecords.enrich([record], fixture["receipts"])

    assert {:ok, rendered} =
             Renderer.render(%{"message" => "Plan reviewed.", "records" => records})

    assert inspect(rendered) =~ "Plan &#124; &lt;!channel&gt;"
    refute inspect(rendered) =~ "<!channel>"
  end

  test "relative timer presentation is anchored to record creation, never delivery time" do
    record = %{
      "kind" => "event_wait",
      "ref" => "record:event_wait:timer",
      "status" => "open",
      "payload" => %{
        "kind" => "timer",
        "deadline_at" => "2026-09-10T10:30:00Z",
        "event_matcher" => %{
          "type" => "after",
          "delay" => "30m",
          "on_timeout" => "Private follow-up."
        },
        "verification" => "Private command instructions."
      }
    }

    records = ReplyRecords.enrich([record], [], %{record["ref"] => ~U[2026-09-09 10:00:00Z]})

    assert {:ok, rendered} =
             Renderer.render(%{
               "message" => "I’ll check after the observation window.",
               "records" => records
             })

    assert inspect(rendered) =~ "2026-09-09 10:30 UTC"
    assert inspect(rendered) =~ "2026-09-10 10:30 UTC"
    refute inspect(rendered) =~ "Private"
  end

  test "retained source labels always fit Slack even after escaping" do
    # Retained evidence allows 500-character labels; escaping must not reject delivery.
    fixture = @fixture |> File.read!() |> Jason.decode!()
    [record | _] = fixture["records"]

    for character <- ["|", "&", "<"] do
      payload =
        record["payload"]
        |> Map.delete("target")
        |> Map.put("source_name", String.duplicate(character, 500))

      assert {:ok, rendered} =
               Renderer.render(%{
                 "message" => "Review.",
                 "records" =>
                   ReplyRecords.enrich([%{record | "payload" => payload}], fixture["receipts"])
               })

      if character == "|", do: refute(inspect(rendered["blocks"]) =~ "Sources")

      for %{"type" => "context", "elements" => elements} <- rendered["blocks"],
          element <- elements do
        assert String.length(element["text"]) <= 3_000
        refute String.trim(element["text"]) == "Sources"
      end
    end
  end
end
