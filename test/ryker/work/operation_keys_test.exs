defmodule Ryker.Work.OperationKeysTest do
  # Coop keeps each operation under its key, and a cancellation proves what it
  # stopped by comparing keys exactly, so a format change strands every
  # operation already sent. These are the formats in use on 2026-10-05.
  use ExUnit.Case, async: true
  alias Ryker.Work.OperationKeys

  @session %{id: "session-1", create_generation: 2}
  @turn %{
    id: "turn-1",
    submit_generation: 3,
    submission_fingerprint: "submission",
    candidate_attempt: 4,
    candidate_sha256: "candidate",
    validation_generation: 5,
    cancel_generation: 6
  }

  test "every key keeps the format Coop already holds operations under" do
    assert OperationKeys.create(@session) == "ryker:work:create:session-1:g2"
    assert OperationKeys.turn(@turn) == "ryker:work:turn:turn-1:g3:submission"
    assert OperationKeys.checkpoint(@turn) == "ryker:work:checkpoint:turn-1:a4:candidate"
    assert OperationKeys.cancel("turn-1", 6) == "ryker:work:cancel:turn-1:g6"
    assert OperationKeys.cancel_close(@turn) == "ryker:work:cancel-close:turn-1:g6"

    assert OperationKeys.validate(@turn, :accept) ==
             "ryker:work:validate:turn-1:a4:g5:candidate:accept"

    assert OperationKeys.validate(@turn, {:reject, []}) ==
             "ryker:work:validate:turn-1:a4:g5:candidate:reject"
  end
end
