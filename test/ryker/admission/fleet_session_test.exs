defmodule Ryker.Admission.FleetSessionTest do
  alias Ryker.Work.Activity
  use Ryker.DataCase, async: true

  alias Ryker.Admission.FleetSession
  alias Ryker.ControlPlane.ModelRequests
  alias Ryker.Ingress.Inbox
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.Session

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
    assert settled.cleanup_status == :discarded
    assert %DateTime{} = settled.closed_at
    assert %DateTime{} = settled.discarded_at

    assert Repo.aggregate(Session, :count, :id) == 1
  end
end
