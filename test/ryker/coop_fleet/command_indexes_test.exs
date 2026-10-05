defmodule Ryker.CoopFleet.CommandIndexesTest do
  use Ryker.DataCase, async: true

  # Workspace, authority and retention read a session's commands by session
  # and kind, and the table had no index on its session: every such read, up
  # to a hundred sessions a retention pass, scanned all of it (2026-10-04
  # review). With sequential scans off, a read the index serves uses it.
  test "a session's commands are read through an index" do
    Repo.query!("SET LOCAL enable_seqscan = off")

    %{rows: plan} =
      Repo.query!(
        "EXPLAIN SELECT id FROM coop_worker_commands WHERE session_id = $1 AND kind = $2",
        [Ecto.UUID.dump!(Ecto.UUID.generate()), "submit_turn"]
      )

    assert plan |> List.flatten() |> Enum.join("\n") =~
             "coop_worker_commands_session_id_kind_index"
  end
end
