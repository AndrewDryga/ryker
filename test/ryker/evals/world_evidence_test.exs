defmodule Ryker.Evals.WorldEvidenceTest do
  use Ryker.DataCase, async: true

  alias Ryker.{Episodes, Repo}
  alias Ryker.Evals.WorldEvidence
  alias Ryker.Fixtures.Episodes, as: Fixtures
  alias Ryker.Work.{ActivityEvent, Custody}

  test "state-call evidence keeps only tool identity and outcome" do
    claim = claim!()

    event!(claim, 1, "responder-state", "remember_answer", nil, %{
      "arguments" => %{"value" => "production secret"},
      "result" => %{"memory_ref" => "memory:secret"}
    })

    event!(claim, 2, "responder-state", "complete_task", %{"message" => "denied"}, %{})
    event!(claim, 3, "github", "create_pull_request", nil, %{})

    assert WorldEvidence.state_calls(claim.episode.id) == [
             %{"outcome" => "succeeded", "tool" => "remember_answer"},
             %{"outcome" => "failed", "tool" => "complete_task"}
           ]
  end

  defp claim! do
    id = Ecto.UUID.generate()

    {:ok, started} =
      Episodes.apply(
        Fixtures.admit_input(%{
          episode_id: id,
          episode_key: id,
          native_input_id: id,
          turn_ref: id
        })
      )

    {:ok, session} =
      Custody.pin_episode(started.episode.id, "policy:world-evidence", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("world-evidence:#{id}", 60, :work)
    turn = Repo.update!(Ecto.Changeset.change(claim.turn, coop_turn_id: "remote:#{id}"))

    %{episode: started.episode, session: session, turn: turn}
  end

  defp event!(claim, sequence, server, tool, error, output) do
    Repo.insert!(%ActivityEvent{
      episode_id: claim.episode.id,
      session_id: claim.session.id,
      remote_event_id: Ecto.UUID.generate(),
      remote_session_id: claim.session.id,
      coop_turn_id: claim.turn.coop_turn_id,
      sequence: sequence,
      kind: "tool.completed",
      version: 1,
      occurred_at: DateTime.add(DateTime.utc_now(), sequence, :microsecond),
      payload: %{
        "input" => %{"server" => server, "tool" => tool},
        "output" => Map.put(output, "error", error),
        "status" => "completed"
      },
      payload_fingerprint: String.duplicate(Integer.to_string(sequence), 64)
    })
  end
end
