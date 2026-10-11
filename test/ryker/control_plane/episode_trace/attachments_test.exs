defmodule Ryker.ControlPlane.EpisodeTrace.AttachmentsTest do
  use Ryker.DataCase, async: true
  alias Ryker.Artifacts.Outputs
  alias Ryker.ControlPlane.EpisodeTrace.Attachments
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Work.Custody

  @now ~U[2026-10-11 12:00:00.000000Z]

  test "an episode's selected file never borrows another turn's identical artifact ref" do
    {episode, turn, fixture} = image_turn!()
    {_foreign_episode, foreign_turn, _fixture} = image_turn!("foreign.png")

    assert foreign_turn.id != turn.id
    selected = Attachments.by_turn(episode, [foreign_turn, turn])
    assert Map.keys(selected) == [turn.id]
    assert [attachment] = Map.fetch!(selected, turn.id)
    assert attachment.name == fixture["artifact"]["name"]
    refute attachment.name == "foreign.png"
    assert attachment.path =~ "/turns/#{turn.id}/"
    refute attachment.path =~ foreign_turn.id
  end

  test "only an accepted delivered and retained reply exposes its selected files" do
    {episode, turn, _fixture} = image_turn!()

    for hidden <- [
          %{turn | accepted_at: nil},
          %{turn | delivered_at: nil},
          %{turn | operational_pruned_at: @now}
        ] do
      assert Attachments.by_turn(episode, [hidden]) == %{}
    end
  end

  test "malformed or missing selections cannot turn generated files into sent attachments" do
    {episode, turn, fixture} = image_turn!()
    ref = fixture["artifact"]["id"]

    for refs <- [nil, "not a list", [], ["artifact_missing"], ["../worker-file", 17, nil]] do
      document = put_in(fixture["delivery_document"], ["outcome", "artifact_refs"], refs)

      assert Attachments.by_turn(episode, [%{turn | delivery_document: document}]) == %{
               turn.id => []
             }
    end

    document =
      put_in(fixture["delivery_document"], ["outcome", "artifact_refs"], [
        nil,
        ref,
        ref,
        "../file"
      ])

    assert [attachment] =
             episode
             |> Attachments.by_turn([%{turn | delivery_document: document}])
             |> Map.fetch!(turn.id)

    assert attachment.ref == ref
  end

  test "only the canonical direct Chat destination supplies an existing download link" do
    {episode, turn, _fixture} = image_turn!()

    for destination <- [
          %{episode | destination_transport: "slack"},
          %{episode | destination_conversation_ref: "control-plane:lab:not-a-uuid"},
          %{episode | destination_thread_ref: "another-thread"}
        ] do
      assert [attachment] = Attachments.by_turn(destination, [turn]) |> Map.fetch!(turn.id)
      assert attachment.path == nil
      assert attachment.name == "blue-circle.png"
    end
  end

  defp image_turn!(name \\ nil) do
    fixture =
      "testdata/work/blue-circle-accepted-delivery.json" |> File.read!() |> Jason.decode!()

    id = Ecto.UUID.generate()
    ref = "control-plane:lab:" <> Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: id,
          episode_key: "attachment:#{id}",
          native_input_id: "attachment-input:#{id}",
          turn_ref: "attachment-turn:#{id}",
          destination: %{transport: "control_plane", conversation_ref: ref, thread_ref: ref}
        })
      )

    {:ok, _session} = WorkSessions.pin_episode(id, "attachment", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("attachment:#{id}", 60, :work)
    assert claim.episode.id == id

    data = fixture["artifact"]["body_base64"] |> String.replace("\n", "") |> Base.decode64!()
    metadata = fixture["artifact"] |> Map.drop(["body_base64"]) |> Map.put("data", data)
    metadata = if name, do: Map.put(metadata, "name", name), else: metadata
    assert {:ok, [_]} = Outputs.put_many(claim.turn.id, [metadata])

    turn = %{
      claim.turn
      | accepted_at: @now,
        delivered_at: @now,
        delivery_document: fixture["delivery_document"]
    }

    {episode, turn, fixture}
  end
end
