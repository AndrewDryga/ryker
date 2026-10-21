defmodule Ryker.Memories.GuidanceEditTest do
  use ExUnit.Case, async: true
  alias Ryker.Memories.GuidanceEdit

  test "changed instructions cannot inherit required outputs for their previous words" do
    payload = %{"text" => "Keep replies short.", "requirements" => ["Report both versions."]}

    assert GuidanceEdit.clear_changed_requirements(
             payload,
             "Report both versions.",
             payload["text"]
           )["requirements"] == []

    assert GuidanceEdit.clear_changed_requirements(payload, payload["text"], payload["text"]) ==
             payload
  end

  test "only corrections with required outputs need the edit notice" do
    assert GuidanceEdit.notice(%{"requirements" => ["Report both versions."]}) =~
             "removes its required checks"

    assert GuidanceEdit.notice(%{"requirements" => []}) == nil
    assert GuidanceEdit.notice(%{}) == nil
  end
end
