defmodule Ryker.Retention.WorkerChangeTest do
  @moduledoc """
  Cleanup against the real fleet placement, with this test acting as the worker.

  Retention reaches a session only through a placement on the worker that
  holds it. These tests change that worker the ways production changed it (a
  newer policy version, an outage, a removal, a lost session) and hold the
  invariant that none of them leaves a cleanup waiting for a person who cannot
  help.
  """

  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.CoopFleet.{Client, Command, ControlPlane, Placement, Worker, WorkerLifecycle}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Retention.Dispatcher
  alias Ryker.Work.{Custody, Session}

  # The live shapes of 2026-09-23: ryker-chat sessions pinned to a8d0aa03…,
  # the worker moved to 3fd0d64f… by a Settings › Models change, authority
  # 947a151e… unchanged, no repository.
  @policy "ryker-chat"
  @started String.duplicate("a", 64)
  @newer String.duplicate("3", 64)
  @authority String.duplicate("9", 64)
  @sandbox String.duplicate("c", 64)
  @workspace "workspace-retention-worker-change"

  # Found live 2026-09-24: two "Closing a worker session stopped · Retry won't
  # help" cards sat on Failures for a day. A model change in Settings rewrote
  # the ryker-chat policy, placement then refused every command for sessions
  # started under the old version, and retention blocked each cleanup after one
  # attempt behind a button that could never work. Close, discard planning and
  # discard do no policy work, so the worker that holds the session takes them
  # under whatever it runs now.
  test "a cleanup whose worker changed policy closes without a person" do
    worker = enroll!("policy-change")
    session = terminal_session!("policy-change", worker)

    # Settings › Models rewrote the policy; the worker reports the newer version.
    poll!(worker, @newer)
    expire_placements!(session)

    fleet = fleet_client(worker, @newer, remote_session(session))

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:policy-change:grace")
    assert {:ok, {:executed, %{phase: :closed}}} = run(fleet, "cleanup:policy-change:close")
    assert {:ok, {:executed, %{phase: :planned}}} = run(fleet, "cleanup:policy-change:plan")
    assert {:ok, {:executed, %{phase: :discarded}}} = run(fleet, "cleanup:policy-change:discard")

    cleaned = Repo.get!(Session, session.id)
    assert cleaned.cleanup_status == :discarded
    assert cleaned.cleanup_receipt["kind"] == "discarded"
    # The session keeps the version it ran under; only the cleanup followed the worker.
    assert cleaned.policy_digest == @started

    assert commands(session) == ~w(get_session close_session get_session plan_discard
             get_session discard_session)

    holder = current_placement!(session)
    assert holder.worker_id == worker
    assert holder.requirements["policy_digest"] == @newer
  end

  # The same trap, one step later: the worker removed from Ryker can never
  # answer again, so waiting on it is waiting forever.
  test "a cleanup whose worker was removed from Ryker ends with a receipt instead of waiting" do
    worker = enroll!("removed")
    session = terminal_session!("removed", worker)
    assert {:ok, %{status: :revoked}} = WorkerLifecycle.revoke(worker, "operator:test")

    fleet = fleet_client(worker, @started, remote_session(session))

    assert {:ok, {:executed, %{phase: :grace}}} = run(fleet, "cleanup:removed:grace")
    assert {:ok, {:executed, %{phase: :discarded}}} = run(fleet, "cleanup:removed:settle")

    settled = Repo.get!(Session, session.id)
    assert settled.cleanup_status == :discarded
    assert settled.cleanup_blocked_from == nil

    assert settled.cleanup_receipt == %{
             "kind" => "worker_removed",
             "local_session_id" => session.id,
             "remote_session_id" => session.coop_session_id,
             "remote_state" => "unreachable",
             "worker_id" => worker
           }

    assert commands(session) == []
  end

  # An outage is not a verdict about the session. The replacement refusal used
  # to be one: a worker away for a minute blocked cleanup for a person.
  test "a cleanup whose worker is away waits for it instead of blocking" do
    worker = enroll!("away")
    session = terminal_session!("away", worker)
    stop_reporting!(worker)
    expire_placements!(session)

    fleet = fleet_client(worker, @started, remote_session(session))

    assert {:ok, %{executed: 1}} = run_pass(fleet, "cleanup:away:grace")
    assert {:ok, %{deferred: 1, blocked: 0}} = run_pass(fleet, "cleanup:away:outage")

    waiting = Repo.get!(Session, session.id)
    assert waiting.cleanup_status == :close_pending
    assert waiting.cleanup_last_error_code == "retention_worker_unavailable"

    # The worker's own report is the evidence that brings the cleanup back.
    poll!(worker, @started)
    assert {:ok, %{executed: 1}} = run_pass(fleet, "cleanup:away:back")
    assert Repo.get!(Session, session.id).cleanup_status == :plan_pending
  end

  # A worker whose Coop no longer knows the session can be asked for nothing,
  # and its own 404 is the proof that nothing is left to close or remove.
  test "a session its worker no longer knows is recorded as already gone" do
    worker = enroll!("forgotten")
    session = terminal_session!("forgotten", worker)

    forgotten =
      fleet_client(worker, @started, fn _command ->
        {:error,
         %{"code" => "session_not_found", "detail" => "session not found", "status" => 404}}
      end)

    assert {:ok, {:executed, %{phase: :grace}}} = run(forgotten, "cleanup:forgotten:grace")
    assert {:ok, {:executed, %{phase: :discarded}}} = run(forgotten, "cleanup:forgotten:settle")

    settled = Repo.get!(Session, session.id)
    assert settled.cleanup_status == :discarded

    assert settled.cleanup_receipt == %{
             "kind" => "remote_absent",
             "local_session_id" => session.id,
             "remote_session_id" => session.coop_session_id,
             "remote_state" => "absent"
           }
  end

  defp run(fleet, worker_ref) do
    Dispatcher.run_once(
      api: Client,
      client: fleet,
      closed_session_grace_seconds: 0,
      lease_seconds: 60,
      max_attempts: 8,
      retained_recheck_seconds: 21_600,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: worker_ref
    )
  end

  defp run_pass(fleet, worker_ref) do
    Dispatcher.run_pass(
      api: Client,
      batch_limit: 25,
      batch_seconds: 30,
      client: fleet,
      closed_session_grace_seconds: 0,
      lease_seconds: 60,
      max_attempts: 8,
      retained_recheck_seconds: 21_600,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: worker_ref
    )
  end

  # The bridge waits on the durable command row; each wait is one worker poll
  # that takes the queued commands and returns what the worker's Coop answered.
  defp fleet_client(worker, digest, answer) do
    assert {:ok, client} =
             Client.new(
               capability_names: ["responder-state"],
               lease_seconds: 60,
               max_waits: 3,
               poll_interval_ms: 1,
               wait: fn -> serve(worker, digest, answer) end,
               workspace_ref: @workspace
             )

    client
  end

  defp serve(worker, digest, answer) do
    assert {:ok, %{"commands" => commands}} =
             ControlPlane.handle_poll(worker, poll(worker, digest))

    results =
      Enum.map(commands, fn command ->
        case answer.(command) do
          {:ok, resource} ->
            %{
              "command_id" => command["command_id"],
              "error" => nil,
              "operation_key" => command["idempotency_key"],
              "resource" => resource,
              "state" => "succeeded"
            }

          {:error, error} ->
            %{
              "command_id" => command["command_id"],
              "error" => error,
              "operation_key" => command["idempotency_key"],
              "resource" => nil,
              "state" => "failed"
            }
        end
      end)

    if results != [] do
      assert {:ok, _response} =
               ControlPlane.handle_poll(worker, poll(worker, digest, command_results: results))
    end

    :ok
  end

  # What the worker's Coop answers for the one session it holds: the version
  # the session was created under, whatever the worker runs now.
  defp remote_session(session) do
    document = fn state, revision ->
      %{
        "authority_digest" => @authority,
        "external_ref" => session.external_ref,
        "id" => session.coop_session_id,
        "policy" => session.policy,
        "policy_digest" => session.policy_digest,
        "revision" => revision,
        "state" => state
      }
    end

    fn command ->
      remote_id = session.coop_session_id

      case {command["kind"], Repo.get_by!(Session, id: session.id).cleanup_status} do
        {"get_session", :close_pending} ->
          {:ok, document.("open", 7)}

        {"close_session", _status} ->
          {:ok,
           %{
             "operation" => operation("op_close", "CloseSession", "session", remote_id),
             "session" => document.("closed", 8)
           }}

        {"get_session", :plan_pending} ->
          {:ok, document.("closed", 8)}

        {"plan_discard", _status} ->
          {:ok,
           %{
             "operation" => operation("op_plan", "PlanDiscard", "discard_plan", remote_id),
             "plan" => %{
               "operation_id" => "op_plan",
               "plan" => %{
                 "revision" => 8,
                 "session_id" => remote_id,
                 "workspace" => %{
                   "accepted_dirty" => false,
                   "accepted_unmerged" => false,
                   "branch" => "coop/session",
                   "dirty" => false,
                   "head" => String.duplicate("a", 40),
                   "running" => false,
                   "status_digest" => String.duplicate("b", 64),
                   "unmerged" => false
                 }
               }
             }
           }}

        {"get_session", :discard_pending} ->
          {:ok, document.("closed", 8)}

        {"discard_session", _status} ->
          {:ok,
           %{
             "operation" => operation("op_discard", "Discard", "session", remote_id),
             "session" => document.("discarded", 9)
           }}
      end
    end
  end

  defp operation(id, method, resource_type, resource_id) do
    %{
      "id" => id,
      "method" => method,
      "resource_id" => resource_id,
      "resource_type" => resource_type,
      "state" => "succeeded"
    }
  end

  defp enroll!(suffix) do
    worker = "retention-#{suffix}-#{System.unique_integer([:positive])}"
    certificate = :crypto.hash(:sha256, worker) |> Base.encode16(case: :lower)
    assert {:ok, _worker} = ControlPlane.authorize_worker(worker, @workspace, certificate)
    poll!(worker, @started)
    worker
  end

  defp poll!(worker, digest) do
    assert {:ok, _response} = ControlPlane.handle_poll(worker, poll(worker, digest))
  end

  defp poll(worker, digest, options \\ []) do
    %{
      "acknowledged_command_ids" => [],
      "command_results" => Keyword.get(options, :command_results, []),
      "event_batches" => [],
      "poll_ref" => "poll:#{worker}:#{System.unique_integer([:positive])}",
      "version" => 1,
      "worker" => %{
        "build_version" => "coop-worker-change",
        "capabilities" => [%{"name" => "responder-state", "version" => "1"}],
        "capacity" => %{
          "cooldown_until" => nil,
          "session_slots_free" => 2,
          "session_slots_total" => 2,
          "state" => "eligible",
          "turn_slots_free" => 2,
          "turn_slots_total" => 2,
          "workspace_slots_free" => 2,
          "workspace_slots_total" => 2
        },
        "clock_at" => DateTime.to_iso8601(database_now!()),
        "id" => worker,
        "policy_authority_digests" => %{@policy => @authority},
        "policy_digests" => %{@policy => digest},
        "protocol_version" => "1",
        "repositories" => [],
        "sandbox_digest" => @sandbox,
        "state" => "eligible",
        "workspace_ref" => @workspace
      }
    }
  end

  # A finished conversation's session, created on this worker under @started.
  defp terminal_session!(suffix, worker) do
    id = Ecto.UUID.generate()
    key = "retention-worker-change:#{suffix}:#{id}"
    turn_ref = "turn:#{suffix}:#{id}"

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: key,
                 native_input_id: "source:#{suffix}:#{id}",
                 occurred_at: database_now!(),
                 turn_ref: turn_ref
               })
             )

    assert {:ok, session} = Custody.pin_episode(id, @policy, @started, @authority, nil)

    assert {:ok, placement} =
             ControlPlane.place_session(
               session.id,
               %{
                 capability_names: ["responder-state"],
                 repository_ref: nil,
                 workspace_ref: @workspace
               },
               60
             )

    assert placement.worker_id == worker

    session =
      session
      |> Ecto.Changeset.change(coop_session_id: "remote_#{suffix}_#{String.replace(id, "-", "")}")
      |> Repo.update!()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.cancel_episode(%{
                 cancel_ref: "cancel:#{suffix}:#{id}",
                 episode_key: key,
                 expected_owner: %{kind: :turn, ref: turn_ref},
                 occurred_at: database_now!()
               })
             )

    session
  end

  # The placement lease ran out while nothing addressed the session.
  defp expire_placements!(session) do
    Repo.update_all(
      from(placement in Placement, where: placement.session_id == ^session.id),
      set: [lease_expires_at: DateTime.add(database_now!(), -1, :second)]
    )
  end

  defp stop_reporting!(worker) do
    {1, nil} =
      Repo.update_all(from(value in Worker, where: value.id == ^worker),
        set: [last_seen_at: DateTime.add(database_now!(), -600, :second)]
      )
  end

  defp commands(session) do
    Repo.all(
      from(command in Command,
        where: command.session_id == ^session.id,
        order_by: [asc: command.inserted_at, asc: command.id],
        select: command.kind
      )
    )
  end

  defp current_placement!(session) do
    Repo.one!(
      from(placement in Placement,
        where: placement.session_id == ^session.id,
        order_by: [desc: placement.generation],
        limit: 1
      )
    )
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
