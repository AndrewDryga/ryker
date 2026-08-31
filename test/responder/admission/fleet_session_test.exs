defmodule Responder.Admission.FleetSessionTest do
  use Responder.DataCase, async: true

  alias Responder.Admission.FleetSession
  alias Responder.Ingress.Inbox
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.Work.Session

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
               workspace_ref: "T123"
             })

    assert {:ok, %{entry: entry}} = Inbox.record(input)

    assert {:ok, session} = FleetSession.ensure(entry, %{name: @policy, digest: @digest})
    assert session.execution_kind == :admission
    assert session.episode_id == nil
    assert session.external_ref == "responder-admission:#{entry.id}:g1"
    assert session.generation == 1
    assert session.cleanup_status == :active

    assert {:ok, duplicate} = FleetSession.ensure(entry, %{name: @policy, digest: @digest})
    assert duplicate.id == session.id

    assert {:error, :admission_fleet_authority_conflict} =
             FleetSession.ensure(entry, %{name: "different", digest: @digest})

    assert {:ok, bound} = FleetSession.bind(entry, "coop-admission-session")
    assert bound.coop_session_id == "coop-admission-session"

    assert {:ok, settled} = FleetSession.settle(entry, "coop-admission-session")
    assert settled.cleanup_status == :discarded
    assert %DateTime{} = settled.closed_at
    assert %DateTime{} = settled.discarded_at

    assert Repo.aggregate(Session, :count, :id) == 1
  end
end
