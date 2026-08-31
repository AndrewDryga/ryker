defmodule Responder.Retention.PlanTest do
  use ExUnit.Case, async: true

  alias Responder.Retention.Plan

  @digest String.duplicate("b", 64)
  @head String.duplicate("a", 40)

  test "one exact clean or explicitly published-unmerged plan is accepted" do
    clean = response(false, false, false)

    assert {:ok, plan} = Plan.prepare(clean, "remote_123", 8, false)
    assert plan["operation_id"] == "op_plan"
    assert plan["workspace"]["dirty"] == false
    assert plan["workspace"]["accepted_unmerged"] == false

    published = response(false, true, true)
    assert {:ok, plan} = Plan.prepare(published, "remote_123", 8, true)
    assert plan["workspace"]["unmerged"]
    assert plan["workspace"]["accepted_unmerged"]
  end

  test "crossed identity, dirty authority, running work, and malformed plans fail closed" do
    valid = response(false, false, false)

    invalid = [
      put_in(valid, ["operation", "method"], "Discard"),
      put_in(valid, ["operation", "resource_id"], "remote_other"),
      put_in(valid, ["plan", "operation_id"], "op_other"),
      put_in(valid, ["plan", "plan", "session_id"], "remote_other"),
      put_in(valid, ["plan", "plan", "revision"], 9),
      put_in(valid, ["plan", "plan", "workspace", "accepted_dirty"], true),
      put_in(valid, ["plan", "plan", "workspace", "running"], true),
      put_in(valid, ["plan", "plan", "workspace", "status_digest"], "wrong"),
      Map.put(valid, "unexpected", true)
    ]

    for document <- invalid do
      assert {:error, {:invalid_discard_plan, _field}} =
               Plan.prepare(document, "remote_123", 8, false)
    end

    assert {:ok, dirty} =
             valid
             |> put_in(["plan", "plan", "workspace", "dirty"], true)
             |> Plan.prepare("remote_123", 8, false)

    refute Plan.discardable?(dirty)
  end

  test "every public envelope and workspace scalar fails closed before cleanup" do
    valid = response(false, false, false)

    malformed = [
      nil,
      Map.put(valid, "operation", nil),
      Map.put(valid, "plan", nil),
      put_in(valid, ["plan", "plan"], "not-a-plan"),
      put_in(valid, ["plan", "plan", "workspace"], nil),
      put_in(valid, ["operation", "state"], "running"),
      put_in(valid, ["operation", "id"], nil),
      put_in(valid, ["plan", "plan", "workspace", "head"], 42),
      put_in(valid, ["plan", "plan", "workspace", "branch"], nil),
      put_in(valid, ["plan", "plan", "workspace", "dirty"], "false"),
      put_in(valid, ["plan", "plan", "workspace", "status_digest"], nil),
      put_in(valid, ["plan", "plan", "workspace", "accepted_unmerged"], true)
    ]

    for document <- malformed do
      assert {:error, {:invalid_discard_plan, _field}} =
               Plan.prepare(document, "remote_123", 8, false)
    end

    assert {:error, {:invalid_discard_plan, :document}} =
             Plan.prepare(valid, "remote_123", 0, false)

    assert {:ok, _plan} =
             valid
             |> put_in(["plan", "plan", "workspace", "head"], "")
             |> Plan.prepare("remote_123", 8, false)

    refute Plan.discardable?(%{})
  end

  defp response(dirty, unmerged, accepted_unmerged) do
    %{
      "operation" => %{
        "id" => "op_plan",
        "method" => "PlanDiscard",
        "resource_id" => "remote_123",
        "resource_type" => "discard_plan",
        "state" => "succeeded"
      },
      "plan" => %{
        "operation_id" => "op_plan",
        "plan" => %{
          "revision" => 8,
          "session_id" => "remote_123",
          "workspace" => %{
            "accepted_dirty" => false,
            "accepted_unmerged" => accepted_unmerged,
            "branch" => "coop/session-123",
            "dirty" => dirty,
            "head" => @head,
            "running" => false,
            "status_digest" => @digest,
            "unmerged" => unmerged
          }
        }
      }
    }
  end
end
