defmodule Responder.State.SourceEventMatcherTest do
  use ExUnit.Case, async: true

  alias Responder.State.SourceEventMatcher

  test "object array filters preserve each required object and all of its fields" do
    # The live Terraform wait must match enriched attachments, without combining
    # unrelated attachments to make an exact-run filter appear satisfied.
    message = "testdata/slack/hcp-terraform-planning.json" |> File.read!() |> Jason.decode!()
    [run, status] = message["attachments"]
    filter = [Map.take(run, ["title", "title_link"]), Map.take(status, ["title"])]

    assert SourceEventMatcher.matches?(filter, [status, run])
    refute SourceEventMatcher.matches?(filter, [run])
    refute SourceEventMatcher.matches?(filter, [status])

    refute SourceEventMatcher.matches?(filter, [
             Map.delete(run, "title"),
             Map.delete(run, "title_link"),
             status
           ])
  end

  test "empty arrays and scalar arrays remain exact and missing fields are not null" do
    assert SourceEventMatcher.matches?([], [])
    refute SourceEventMatcher.matches?([], [%{}])
    refute SourceEventMatcher.matches?([], nil)
    assert SourceEventMatcher.matches?(["ready", "saved"], ["ready", "saved"])
    refute SourceEventMatcher.matches?(["ready"], ["ready", "saved"])
    refute SourceEventMatcher.matches?(["ready", "saved"], ["saved", "ready"])
    refute SourceEventMatcher.matches?([%{}, "ready"], [%{}, "ready", "saved"])
    refute SourceEventMatcher.matches?(%{"state" => nil}, %{})
    assert SourceEventMatcher.matches?(%{"state" => nil}, %{"state" => nil})
    refute SourceEventMatcher.matches?(%{}, [])
    refute SourceEventMatcher.matches?([%{}], [])
    refute SourceEventMatcher.matches?([%{}], [nil])
  end
end
