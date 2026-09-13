defmodule Ryker.Work.StateBindingScopeTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.CoopFleet.{ControlPlane, Placement}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Repo
  alias Ryker.Work.{Custody, StateBinding}

  @authority_digest String.duplicate("d", 64)
  @policy_digest String.duplicate("b", 64)
  @sandbox_digest String.duplicate("a", 64)

  # The placement lease was compared as `$1::timestamp > clock_timestamp()`:
  # the lease's UTC instant, stripped of its zone, read back in whatever zone
  # the database session happened to run in. Under a zone west of UTC an
  # expired placement kept answering state-tool calls; east of UTC a live one
  # was refused. Production runs the database in UTC, which is the only reason
  # this never fired; the comparison must not depend on that setting.
  test "an expired placement lease is not current whatever zone the database session runs in" do
    session = session!("scope-zone")
    authorize_and_poll!("worker-scope-zone")

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
                 repository_ref: "ryker",
                 workspace_ref: "workspace-main"
               },
               60
             )

    assert {:ok, "placement:" <> _rest} = StateBinding.current_scope(session)

    expired_at = DateTime.add(Repo.now!(), -3_600, :second)

    Repo.update_all(from(p in Placement, where: p.id == ^placement.id),
      set: [lease_expires_at: expired_at]
    )

    # Chicago is five hours behind UTC in September: a zone-stripped UTC
    # instant read as local time lands five hours in the future.
    Repo.query!("SET LOCAL TIME ZONE 'America/Chicago'")

    assert StateBinding.current_scope(session) ==
             {:error, {:work_state_tools_placement_not_current, session.id}}

    Repo.update_all(from(p in Placement, where: p.id == ^placement.id),
      set: [lease_expires_at: DateTime.add(Repo.now!(), 3_600, :second)]
    )

    # Kyiv is three hours ahead: the same reading puts a live lease in the past.
    Repo.query!("SET LOCAL TIME ZONE 'Europe/Kyiv'")

    assert {:ok, "placement:" <> _rest} = StateBinding.current_scope(session)
  end

  defp session!(suffix) do
    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "scope:#{suffix}:#{Ecto.UUID.generate()}",
        native_input_id: "source:#{suffix}:#{Ecto.UUID.generate()}",
        occurred_at: Repo.now!(),
        turn_ref: "turn:#{suffix}:#{Ecto.UUID.generate()}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, session} =
             Custody.pin_episode(
               command.episode_id,
               "work-read-only",
               @policy_digest,
               @authority_digest,
               "ryker"
             )

    session
  end

  defp authorize_and_poll!(worker_id) do
    assert {:ok, _worker} =
             ControlPlane.authorize_worker(
               worker_id,
               "workspace-main",
               :crypto.hash(:sha256, worker_id) |> Base.encode16(case: :lower)
             )

    assert {:ok, _response} =
             ControlPlane.handle_poll(worker_id, %{
               "acknowledged_command_ids" => [],
               "command_results" => [],
               "event_batches" => [],
               "poll_ref" => "poll:#{worker_id}:hello",
               "version" => 1,
               "worker" => %{
                 "build_version" => "coop-abc123",
                 "capabilities" => [%{"name" => "responder-state", "version" => "1"}],
                 "capacity" => %{
                   "cooldown_until" => nil,
                   "session_slots_free" => 2,
                   "session_slots_total" => 4,
                   "state" => "eligible",
                   "turn_slots_free" => 2,
                   "turn_slots_total" => 4,
                   "workspace_slots_free" => 2,
                   "workspace_slots_total" => 4
                 },
                 "clock_at" => DateTime.to_iso8601(Repo.now!()),
                 "id" => worker_id,
                 "policy_authority_digests" => %{"work-read-only" => @authority_digest},
                 "policy_digests" => %{"work-read-only" => @policy_digest},
                 "protocol_version" => "1",
                 "repositories" => [%{"ref" => "ryker", "revision" => "commit:abc123"}],
                 "sandbox_digest" => @sandbox_digest,
                 "state" => "eligible",
                 "storage" => nil,
                 "workspace_ref" => "workspace-main"
               }
             })
  end
end
