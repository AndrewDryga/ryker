defmodule Ryker.Emisar.ConnectionsTest do
  use Ryker.DataCase, async: true

  alias Ryker.Emisar.{Approvals, Connections, Operator}
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Settings
  alias Ryker.State.Records
  alias Ryker.Work.Custody

  @actor "control-plane:local"
  @digest String.duplicate("d", 64)
  @now ~U[2026-09-19 12:00:00.000000Z]

  test "two accounts stay isolated across routing, session pins and colliding request IDs" do
    settings = configured!()

    assert {:ok, %{connection_ref: "production", account_ref: "account-production"}} =
             Connections.resolve(settings, "repo-one", nil)

    assert {:ok, %{connection_ref: "staging", account_ref: "account-staging"}} =
             Connections.resolve(settings, "repo-two", nil)

    first = waiting_approval!("one", "repo-one", "production", "account-production")
    second = waiting_approval!("two", "repo-two", "staging", "account-staging")

    assert first.session.emisar_connection_ref == "production"
    assert second.session.emisar_connection_ref == "staging"

    assert Approvals.get_by_request_id("production", "request-shared").episode_id ==
             first.episode.id

    assert Approvals.get_by_request_id("staging", "request-shared").episode_id ==
             second.episode.id

    assert {:ok, %{approval: production}} =
             Approvals.claim_next("production", "production-monitor", 60)

    assert production.episode_id == first.episode.id

    assert {:ok, %{approval: staging}} =
             Approvals.claim_next("staging", "staging-monitor", 60)

    assert staging.episode_id == second.episode.id
    assert {:ok, %{connection_ref: "production"}} = Operator.fetch("production/request-shared")
    assert {:ok, %{connection_ref: "staging"}} = Operator.fetch("staging/request-shared")

    production_binding =
      Enum.find(settings.emisar_bindings, &(&1.scope_ref == "repo-one"))

    assert {:ok, rebound} =
             Settings.put_emisar_binding(
               %{
                 id: production_binding.id,
                 scope_kind: :repository,
                 scope_ref: "repo-one",
                 purpose: :standard,
                 connection_ref: "staging"
               },
               Settings.fetch!().installation.revision,
               @actor
             )

    assert {:ok, %{connection_ref: "staging"}} =
             Connections.resolve(rebound, "repo-one", nil)

    assert first.session.emisar_connection_ref == "production"

    assert {:error, {:invalid_settings, _references}} =
             Settings.delete_emisar_connection(
               "production",
               rebound.installation.revision,
               @actor
             )
  end

  defp configured! do
    {:ok, snapshot} = Settings.initialize(@actor)
    snapshot = put_repository!(snapshot, "repo-one")
    snapshot = put_repository!(snapshot, "repo-two")
    snapshot = put_connection!(snapshot, "production", "account-production")
    snapshot = put_connection!(snapshot, "staging", "account-staging")
    snapshot = put_binding!(snapshot, "repo-one", "production")
    put_binding!(snapshot, "repo-two", "staging")
  end

  defp put_repository!(snapshot, ref) do
    {:ok, saved} =
      Settings.put_repository(%{ref: ref}, snapshot.installation.revision, @actor)

    saved
  end

  defp put_connection!(snapshot, ref, account_ref) do
    {:ok, saved} =
      Settings.put_emisar_connection(
        %{
          ref: ref,
          display_name: String.capitalize(ref),
          rpc_url: "https://#{ref}.emisar.example/api/mcp/rpc",
          account_ref: account_ref,
          account_label: String.capitalize(ref),
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: @now
        },
        snapshot.installation.revision,
        @actor
      )

    saved
  end

  defp put_binding!(snapshot, repository_ref, connection_ref) do
    {:ok, saved} =
      Settings.put_emisar_binding(
        %{
          scope_kind: :repository,
          scope_ref: repository_ref,
          purpose: :standard,
          connection_ref: connection_ref
        },
        snapshot.installation.revision,
        @actor
      )

    saved
  end

  defp waiting_approval!(suffix, repository_ref, connection_ref, account_ref) do
    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "emisar-connections:#{suffix}",
                 native_input_id: "source:#{suffix}",
                 occurred_at: @now,
                 payload: %{"text" => "Run a governed action."},
                 turn_ref: "turn:#{suffix}"
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(episode_id, "test-policy", @digest, repository_ref)

    # This focused suite can run against a shared development test database
    # containing older abandoned work. Make the fixture the oldest eligible
    # episode so the public claimant deterministically takes the one under test.
    Episode
    |> Repo.get!(episode_id)
    |> Ecto.Changeset.change(updated_at: ~U[2000-01-01 00:00:00.000000Z])
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    assert claim.episode.id == episode_id

    assert {:ok, record} =
             Records.create(
               Records.token(claim.turn),
               "operation:#{suffix}",
               "emisar_approval",
               %{
                 "action_id" => "deploy",
                 "account_ref" => account_ref,
                 "approval_url" =>
                   "https://#{connection_ref}.emisar.example/app/approvals/request-shared",
                 "connection_ref" => connection_ref,
                 "expires_at" => "2099-09-19T12:00:00.000000Z",
                 "operation_id" => "operation:#{suffix}",
                 "pack_ref" => "deploy@1#sha256:abc",
                 "request_id" => "request-shared",
                 "rpc_url" => "https://#{connection_ref}.emisar.example/api/mcp/rpc",
                 "run_id" => "run:#{suffix}",
                 "runner_ref" => "runner:#{suffix}",
                 "status" => "pending_approval"
               }
             )

    assert {:ok, _waiting} =
             Episodes.apply(%Command.StartWait{
               deadline_at: ~U[2099-09-19 12:00:00.000000Z],
               episode_key: transition.episode.key,
               expected_turn_ref: claim.turn.turn_ref,
               kind: :event,
               occurred_at: DateTime.add(@now, 1, :second),
               wait_ref: record.ref
             })

    %{episode: transition.episode, session: session}
  end
end
