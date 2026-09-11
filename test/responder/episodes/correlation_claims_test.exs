defmodule Responder.Episodes.CorrelationClaimsTest do
  use Responder.DataCase, async: true

  alias Responder.Episodes
  alias Responder.Episodes.CorrelationClaims
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo

  @now ~U[2026-09-11 08:00:00.000000Z]

  test "one trusted occurrence has at most one active owner inside its scope and namespace" do
    # Two channels can report the same run or alert start. Without an
    # exclusive claim each admission would create its own active work.
    devops = episode!("claims:devops")
    alerts = episode!("claims:alerts")

    assert {:ok, claim} = claim(devops, "slack:T1", "slack:app:B1", "run-9R1YWKbeFV8rtWRQ")
    assert claim.status == :active and claim.lifecycle_state == :active

    assert {:error, {:occurrence_claimed, owner}} =
             claim(alerts, "slack:T1", "slack:app:B1", "run-9R1YWKbeFV8rtWRQ")

    assert owner.episode_id == devops.id

    # The same identifier from another workspace or another reporting app is
    # a different claim: shared strings never cross a security domain.
    assert {:ok, _other_scope} = claim(alerts, "slack:T2", "slack:app:B1", "run-9R1YWKbeFV8rtWRQ")
    assert {:ok, _other_app} = claim(alerts, "slack:T1", "slack:app:B2", "run-9R1YWKbeFV8rtWRQ")

    assert CorrelationClaims.owner("slack:T1", "slack:app:B1", "run-9R1YWKbeFV8rtWRQ").id ==
             claim.id
  end

  test "a claim retried for the same input is idempotent" do
    devops = episode!("claims:retry")
    assert {:ok, first} = claim(devops, "slack:T1", "slack:app:B1", "alert:started:1")
    assert {:ok, again} = claim(devops, "slack:T1", "slack:app:B1", "alert:started:1")
    assert again.id == first.id
  end

  test "resolving one signal marks only that claim terminal and leaves the other firing" do
    incident = episode!("claims:signals")
    assert {:ok, a} = claim(incident, "slack:T1", "slack:app:B1", "alert-a:started:1")
    assert {:ok, b} = claim(incident, "slack:T1", "slack:app:B1", "alert-b:started:1")

    assert {:ok, %{id: recovered_id, lifecycle_state: :terminal}} =
             claim(incident, "slack:T1", "slack:app:B1", "alert-a:started:1", :terminal)

    assert recovered_id == a.id

    assert [%{id: a_id, lifecycle_state: :terminal}, %{id: b_id, lifecycle_state: :active}] =
             CorrelationClaims.for_episode(incident.id)

    assert {a_id, b_id} == {a.id, b.id}
    refute CorrelationClaims.all_terminal?(incident.id)
  end

  test "retiring an episode's claims frees the occurrence for a corrected owner without deleting history" do
    wrong = episode!("claims:wrong")
    right = episode!("claims:right")
    assert {:ok, claim} = claim(wrong, "slack:T1", "slack:app:B1", "run-1")

    assert {:ok, 1} =
             Repo.transaction(fn ->
               {:ok, count} = CorrelationClaims.retire_in_transaction(wrong.id)
               count
             end)

    assert [%{id: retired_id, status: :retired}] = CorrelationClaims.for_episode(wrong.id)
    assert retired_id == claim.id
    assert {:ok, _} = claim(right, "slack:T1", "slack:app:B1", "run-1")
  end

  defp claim(episode, scope_ref, namespace, occurrence_ref, lifecycle_state \\ :active) do
    Repo.transaction(fn ->
      case CorrelationClaims.claim_in_transaction(%{
             episode_id: episode.id,
             input_ref: "admit:#{episode.key}",
             scope_ref: scope_ref,
             namespace: namespace,
             occurrence_ref: occurrence_ref,
             lifecycle_state: lifecycle_state,
             established_at: @now
           }) do
        {:ok, claim} -> claim
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp episode!(key) do
    {:ok, transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: Ecto.UUID.generate(),
          episode_key: key,
          native_input_id: "input:#{key}"
        })
      )

    transition.episode
  end
end
