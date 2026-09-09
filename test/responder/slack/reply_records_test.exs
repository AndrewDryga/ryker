defmodule Responder.Slack.ReplyRecordsTest do
  use Responder.DataCase, async: true
  import Ecto.Query

  alias Responder.{Episodes, Repo}
  alias Responder.Fixtures.Episodes, as: Fixtures
  alias Responder.Slack.ReplyRecords
  alias Responder.State.{Record, Records}
  alias Responder.Work.{ActivityEvent, Custody, Turn}

  @fixture Path.expand("../../../testdata/slack/terraform-source-activity.json", __DIR__)
  @reply Path.expand("../../../testdata/slack/terraform-deployment-reply.json", __DIR__)

  test "source links use retained receipts from this episode, never foreign or retired activity" do
    # A bare source UUID used to be displayed despite the exact run URL already being on disk.
    first = claim!()

    payload =
      @reply |> File.read!() |> Jason.decode!() |> get_in(["records", Access.at(0), "payload"])

    {:ok, record} = Records.create(Records.token(first.turn), "plan", "evidence", payload)
    activity = @fixture |> File.read!() |> Jason.decode!()
    event = event!(first, activity)

    [projected] = ReplyRecords.documents("slack", first.episode.id, [record])
    assert projected["presentation"]["source_url"] =~ "/runs/01a085b2-310a"
    assert projected["payload"] == record.payload
    assert Repo.get!(Record, record.id).payload == payload

    second = claim!()
    {:ok, other} = Records.create(Records.token(second.turn), "plan", "evidence", payload)
    assert [plain] = ReplyRecords.documents("slack", second.episode.id, [other])
    refute plain["presentation"]

    Repo.update_all(from(a in ActivityEvent, where: a.id == ^event.id),
      set: [operational_pruned_at: DateTime.utc_now()]
    )

    [plain] = ReplyRecords.documents("slack", first.episode.id, [record])
    refute plain["presentation"]

    Repo.update_all(from(a in ActivityEvent, where: a.id == ^event.id),
      set: [operational_pruned_at: nil]
    )

    Repo.update_all(from(t in Turn, where: t.id == ^first.turn.id),
      set: [operational_pruned_at: DateTime.utc_now()]
    )

    [plain] = ReplyRecords.documents("slack", first.episode.id, [record])
    refute plain["presentation"]
  end

  test "receipt-shaped stdout from another tool is not Emisar source provenance" do
    claim = claim!()

    payload =
      @reply |> File.read!() |> Jason.decode!() |> get_in(["records", Access.at(0), "payload"])

    {:ok, record} = Records.create(Records.token(claim.turn), "plan", "evidence", payload)

    activity =
      @fixture |> File.read!() |> Jason.decode!() |> put_in(["input", "tool"], "read_file")

    event!(claim, activity)
    [plain] = ReplyRecords.documents("slack", claim.episode.id, [record])
    refute plain["presentation"]
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
      Custody.pin_episode(started.episode.id, "policy:links", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("links:#{id}", 60, :work)
    turn = Repo.update!(Ecto.Changeset.change(claim.turn, coop_turn_id: "remote:#{id}"))
    %{episode: started.episode, session: session, turn: turn}
  end

  defp event!(claim, payload) do
    Repo.insert!(%ActivityEvent{
      episode_id: claim.episode.id,
      session_id: claim.session.id,
      remote_event_id: Ecto.UUID.generate(),
      remote_session_id: claim.session.id,
      coop_turn_id: claim.turn.coop_turn_id,
      sequence: 1,
      kind: "tool.completed",
      version: 1,
      occurred_at: DateTime.utc_now(),
      payload: payload,
      payload_fingerprint: String.duplicate("a", 64)
    })
  end
end
