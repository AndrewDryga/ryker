defmodule Ryker.Admission.FleetSessionTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Admission.FleetSession
  alias Ryker.ControlPlane.ModelRequests
  alias Ryker.FakeRetentionCoopAPI, as: RetentionAPI
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Retention.Dispatcher, as: RetentionDispatcher
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.{Activity, Session}

  @policy "admission-read-only"
  @digest String.duplicate("a", 64)

  test "one admission generation has fleet identity without fabricating a kernel episode" do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Classify this on the remote fleet."},
               event_kind: :message,
               event_ref: "Ev-fleet-admission",
               message_ref: "1787832000.000100",
               occurred_at: ~U[2026-08-30 12:00:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T4E9BBB321532"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, session} = FleetSession.ensure(entry, %{name: @policy, digest: @digest})
    assert session.execution_kind == :admission
    assert session.episode_id == nil
    assert session.external_ref == "ryker-admission:#{entry.id}:g1"
    assert session.generation == 1
    assert session.cleanup_status == :active

    assert {:ok, duplicate} = FleetSession.ensure(entry, %{name: @policy, digest: @digest})
    assert duplicate.id == session.id

    assert {:error, :admission_fleet_authority_conflict} =
             FleetSession.ensure(entry, %{name: "different", digest: @digest})

    assert {:ok, bound} = FleetSession.bind(entry, "coop-admission-session")
    assert bound.coop_session_id == "coop-admission-session"

    # Routing can call tools before it decides to create an episode. Its activity must not vanish.
    event = %{
      "id" => "routing-call",
      "session_id" => bound.coop_session_id,
      "sequence" => 1,
      "turn_id" => "routing-turn",
      "type" => "tool.started",
      "version" => 1,
      "occurred_at" => "2026-09-06T02:35:37.000000Z",
      "payload" => %{
        "tool_call_id" => "routing-tool",
        "title" => "Read channel history",
        "input" => %{"channel" => "infra"}
      }
    }

    assert {:ok, %{inserted: 1, cursor: 1}} =
             Activity.ingest_fleet(bound.id, bound.coop_session_id, 0, [event])

    activity = Repo.one!(Ryker.Work.ActivityEvent)
    assert activity.episode_id == nil
    assert Map.get(activity, :admission_input_id) == entry.id
    assert {:ok, request} = ModelRequests.project_input(entry.id, %{})
    assert request.episode_ref == nil
    assert request.selected.tools.total == 1
    assert hd(request.selected.tools.items).artifact.text =~ "Read channel history"

    assert {:ok, %{inserted: 0}} =
             Activity.ingest_fleet(bound.id, bound.coop_session_id, 1, [event])

    assert {:ok, settled} = FleetSession.settle(entry, "coop-admission-session")
    assert settled.cleanup_status == :plan_pending
    assert %DateTime{} = settled.closed_at
    assert is_nil(settled.discarded_at)

    # Production, 2026-09-20: successful admission marked this row discarded
    # after CloseSession, so retention never sent PlanDiscard/Discard and every
    # routing fork remained protected on the worker. Once the input advances,
    # the shared cleanup state machine must remove the exact remote session.
    {1, nil} =
      Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
        set: [execution_generation: 2]
      )

    remote = %{
      "external_ref" => settled.external_ref,
      "id" => settled.coop_session_id,
      "policy" => settled.policy,
      "policy_digest" => settled.policy_digest,
      "revision" => 2,
      "state" => "closed"
    }

    {:ok, cleanup} = RetentionAPI.start_link(sessions: [remote])

    assert {:ok, {:executed, %{phase: :planned}}} = retention(cleanup, "plan")
    assert {:ok, {:executed, %{phase: :discarded}}} = retention(cleanup, "discard")

    assert Repo.get!(Session, settled.id).cleanup_status == :discarded
    assert RetentionAPI.remote_session(cleanup, settled.coop_session_id)["state"] == "discarded"

    assert Repo.aggregate(Session, :count, :id) == 1
  end

  test "an older admission generation is remotely discarded after a failed close" do
    # Production, 2026-09-20: generation 1 received the model response, its
    # CloseSession command failed with 500, generation 2 completed, and no
    # recovery path ever retried or discarded generation 1's physical fork.
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Retry this admission safely."},
               event_kind: :message,
               event_ref: "Ev-fleet-admission-orphan",
               message_ref: "1787832000.000200",
               occurred_at: ~U[2026-08-30 12:01:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T4E9BBB321532"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    assert {:ok, _session} = FleetSession.ensure(entry, %{name: @policy, digest: @digest})
    assert {:ok, session} = FleetSession.bind(entry, "coop-admission-orphan")

    {1, nil} =
      Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
        set: [execution_generation: 2]
      )

    remote = %{
      "external_ref" => session.external_ref,
      "id" => session.coop_session_id,
      "policy" => session.policy,
      "policy_digest" => session.policy_digest,
      "revision" => 1,
      "state" => "open"
    }

    {:ok, cleanup} = RetentionAPI.start_link(sessions: [remote])

    assert {:ok, {:executed, %{phase: :closed}}} = retention(cleanup, "orphan-close")
    assert {:ok, {:executed, %{phase: :planned}}} = retention(cleanup, "orphan-plan")
    assert {:ok, {:executed, %{phase: :discarded}}} = retention(cleanup, "orphan-discard")

    assert Repo.get!(Session, session.id).cleanup_status == :discarded
    assert RetentionAPI.remote_session(cleanup, session.coop_session_id)["state"] == "discarded"
  end

  defp retention(client, suffix) do
    RetentionDispatcher.run_once(
      api: RetentionAPI,
      client: client,
      closed_session_grace_seconds: 900,
      lease_seconds: 60,
      max_attempts: 8,
      retained_recheck_seconds: 21_600,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "admission-cleanup:#{suffix}"
    )
  end
end
