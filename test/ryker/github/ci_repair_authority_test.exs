defmodule Ryker.GitHub.CIRepairAuthorityTest do
  use Ryker.DataCase, async: true
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.GitHub.CIRepairAuthority
  alias Ryker.Work

  test "an earlier human request cannot authorize an old automatic failed-CI wakeup" do
    id = Repo.generate_id()
    session = %Work.Session{episode_id: id}
    admit!(id, 1, %{"actor" => %{"kind" => "user"}})
    assert CIRepairAuthority.ordinary_publication_allowed?(session)

    admit!(id, 2, %{
      "actor" => %{"kind" => "system"},
      "content" => %{"lifecycle" => %{"kind" => "checks", "state" => "failed"}}
    })

    refute CIRepairAuthority.ordinary_publication_allowed?(session)
    admit!(id, 3, %{"actor" => %{"kind" => "user"}})
    assert CIRepairAuthority.ordinary_publication_allowed?(session)
  end

  defp admit!(id, n, payload) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "legacy-ci:#{id}",
        native_input_id: "legacy-ci:#{id}:#{n}",
        turn_ref: "turn:legacy-ci:#{id}:1",
        payload: payload
      })

    assert {:ok, _transition} = Episodes.apply(command)

    if n > 1 do
      transfer =
        EpisodeFixtures.transfer_owner(%{
          episode_key: command.episode_key,
          expected_owner: %{kind: :turn, ref: "turn:legacy-ci:#{id}:#{n - 1}"},
          new_owner: %{kind: :turn, ref: "turn:legacy-ci:#{id}:#{n}"},
          required_input_ref: Episodes.Command.dedupe_key(command),
          transfer_ref: "transfer:legacy-ci:#{id}:#{n}"
        })

      assert {:ok, _transition} = Episodes.apply(transfer)
    end
  end
end
