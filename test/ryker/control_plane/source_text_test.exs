defmodule Ryker.ControlPlane.SourceTextTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.SourceText

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
