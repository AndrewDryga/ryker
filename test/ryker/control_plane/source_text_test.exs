defmodule Ryker.ControlPlane.SourceTextTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.SourceText

  test "a publication result reads only its saved status and receipt" do
    event = %{
      "kind" => "publication_result",
      "status" => "published",
      "published_revision" => %{
        "commit_sha" => String.duplicate("6", 40),
        "pull_request_url" => "https://github.com/acme/ryker/pull/91"
      },
      "error_code" => nil
    }

    preview = SourceText.event_preview(event)
    assert preview.actor == "Publication result"
    assert preview.text =~ "Publication: published"
    assert preview.text =~ event["published_revision"]["commit_sha"]
    assert preview.text =~ event["published_revision"]["pull_request_url"]
    assert SourceText.from_content(event) == preview.text

    blocked = %{
      event
      | "status" => "not_published",
        "published_revision" => %{},
        "error_code" => "publication_branch_changed"
    }

    assert SourceText.event_preview(blocked).text ==
             "Publication: not published\nReason: publication_branch_changed"

    assert SourceText.event_preview(event) == preview

    assert SourceText.event_preview(%{
             "kind" => "publication_result",
             "status" => [],
             "published_revision" => "invalid"
           }).text == "Publication: unknown"
  end

  test "timer wrapper and direct payload have the same recorded intent" do
    input =
      "testdata/control_plane/timer-due.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("input")

    event = input["content"]["content"]
    assert SourceText.event_preview(input) == SourceText.event_preview(event)
    assert SourceText.from_content(event) == SourceText.event_preview(input).text
    refute SourceText.event_preview(input).text =~ "record:event_wait:"
    assert SourceText.event_preview(%{"kind" => "unknown"}) == nil
  end

  test "missing optional timer fields do not invent a deadline or successful check" do
    assert SourceText.event_preview(%{"kind" => "timer_due", "deadline_at" => "invalid"}) ==
             %{actor: "Scheduled check", text: "A scheduled check is due."}

    assert SourceText.event_preview(%{
             "kind" => "scheduled_task",
             "schedule" => %{
               "title" => "Weekly maintenance",
               "task" => "Check security updates"
             }
           }) == %{actor: "Scheduled work", text: "Weekly maintenance\n\nCheck security updates"}
  end
end
