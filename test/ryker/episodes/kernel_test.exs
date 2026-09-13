defmodule Ryker.Episodes.KernelTest do
  use ExUnit.Case, async: true
  alias Ryker.Episodes.{Command, Kernel, Reducer}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures

  test "an exact retry returns the original transition without advancing state" do
    command = EpisodeFixtures.admit_input()
    assert {:ok, first} = Kernel.apply(nil, nil, command)

    assert {:ok, duplicate} = Kernel.apply(first.episode, first.event, command)
    assert duplicate.status == :duplicate
    assert duplicate.event == first.event
    assert duplicate.episode == first.episode
  end

  test "timestamp precision does not turn the same command into a conflicting retry" do
    # Elixir commonly constructs whole-second DateTimes with precision zero,
    # while Postgres returns the same instant with precision six. A retry after
    # persistence must still be byte-identical to the accepted command.
    command = EpisodeFixtures.admit_input(%{occurred_at: ~U[2026-08-27 12:00:00Z]})
    assert {:ok, first} = Kernel.apply(nil, nil, command)

    persisted_shape = %{command | occurred_at: ~U[2026-08-27 12:00:00.000000Z]}

    assert {:ok, duplicate} = Kernel.apply(first.episode, first.event, persisted_shape)
    assert duplicate.status == :duplicate
    assert duplicate.event.occurred_at.microsecond == {0, 6}
  end

  test "a retry with different content is rejected before current state can hide the conflict" do
    command = EpisodeFixtures.admit_input()
    assert {:ok, first} = Kernel.apply(nil, nil, command)

    changed = %{command | payload: %{"status" => "resolved"}}

    assert Kernel.apply(first.episode, first.event, changed) ==
             {:error,
              {:idempotency_conflict,
               dedupe_key: Command.dedupe_key(command),
               stored_fingerprint: first.event.fingerprint,
               submitted_fingerprint: Command.fingerprint(changed)}}
  end

  test "an unseen command is decided by the reducer" do
    command = EpisodeFixtures.admit_input()

    assert Kernel.apply(nil, nil, command) == Reducer.decide(nil, command)
  end

  test "a later owner cycle has a fresh host-owned transition slot" do
    assert {:ok, admitted} = Kernel.apply(nil, nil, EpisodeFixtures.admit_input())

    to_b = EpisodeFixtures.transfer_owner(%{transfer_ref: "transfer-a-b"})
    assert {:ok, moved_b} = Kernel.apply(admitted.episode, nil, to_b)

    to_a =
      EpisodeFixtures.transfer_owner(%{
        expected_owner: %{kind: :turn, ref: "turn-1-replacement"},
        new_owner: %{kind: :turn, ref: "turn-1"},
        transfer_ref: "transfer-b-a"
      })

    assert {:ok, moved_a} = Kernel.apply(moved_b.episode, nil, to_a)

    to_c =
      EpisodeFixtures.transfer_owner(%{
        new_owner: %{kind: :turn, ref: "turn-3"},
        transfer_ref: "transfer-a-c"
      })

    assert {:ok, moved_c} = Kernel.apply(moved_a.episode, nil, to_c)
    assert moved_c.episode.owner_ref == "turn-3"
  end

  test "a lost cancellation response reconciles to one terminal event" do
    assert {:ok, admitted} = Kernel.apply(nil, nil, EpisodeFixtures.admit_input())
    cancel = EpisodeFixtures.cancel_episode()
    assert {:ok, first} = Kernel.apply(admitted.episode, nil, cancel)

    assert {:ok, duplicate} = Kernel.apply(first.episode, first.event, cancel)
    assert duplicate.status == :duplicate
    assert duplicate.event == first.event
    assert duplicate.episode.state == :cancelled
  end
end
