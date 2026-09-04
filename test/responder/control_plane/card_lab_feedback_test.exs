defmodule Responder.ControlPlane.CardLabFeedbackTest do
  use Responder.DataCase, async: true

  alias Responder.ControlPlane.CardLabFeedback

  test "feedback is append-only and scoped to one exact specimen state" do
    assert {:ok, first} =
             CardLabFeedback.record(
               "task-card",
               "working",
               "needs_work",
               "Make the active run louder."
             )

    assert {:ok, second} =
             CardLabFeedback.record("task-card", "working", "good", "Controls are clear now.")

    assert {:ok, _other} =
             CardLabFeedback.record("incident-room", "resolved", "approved", "Ship this state.")

    assert [listed_second, listed_first] = CardLabFeedback.list("task-card", "working")
    assert listed_second.id == second.id
    assert listed_first.id == first.id
    assert listed_first.note == "Make the active run louder."
    assert listed_second.verdict == "good"
  end

  test "feedback rejects unknown specimens and malformed values" do
    assert CardLabFeedback.record("missing", "state", "good", "No") ==
             {:error, :card_lab_specimen_not_found}

    assert {:error, changeset} = CardLabFeedback.record("task-card", "working", "wrong", "No")
    assert Enum.any?(changeset.errors, &match?({:verdict, {"is invalid", _metadata}}, &1))

    assert {:error, changeset} = CardLabFeedback.record("task-card", "working", "good", "")
    assert Enum.any?(changeset.errors, &match?({:note, {"can't be blank", _metadata}}, &1))
  end
end
