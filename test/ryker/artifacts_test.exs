defmodule Ryker.ArtifactsTest do
  use Ryker.DataCase, async: true

  alias Ryker.Artifacts
  alias Ryker.Artifacts.Outputs
  alias Ryker.Artifacts.References
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Repo
  alias Ryker.Work.{Custody, Submission}

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0>>

  test "image delivery is supported only by live Slack and Lab destinations" do
    for transport <- ~w(slack control_plane github), mode <- [:live, :shadow] do
      assert Outputs.delivery_supported?(%{
               execution_mode: mode,
               destination_transport: transport
             }) == (mode == :live and transport in ~w(slack control_plane))
    end
  end

  test "one source file owns one immutable content-addressed artifact" do
    attributes = %{
      data: @png,
      media_type: "image/png",
      name: "failure.png",
      source_kind: "slack",
      source_ref: "T123:F123"
    }

    assert {:ok, artifact} = Artifacts.put(attributes)
    assert artifact.ref =~ "artifact:input:"
    assert artifact.sha256 == digest(@png)
    assert artifact.byte_size == byte_size(@png)

    assert {:ok, duplicate} = Artifacts.put(attributes)
    assert duplicate.id == artifact.id

    assert {:ok, [loaded]} = Artifacts.fetch_many([artifact.ref])
    assert loaded.data == @png
    assert {:ok, ^loaded} = Artifacts.fetch_source("slack", "T123:F123")

    assert Artifacts.put(%{attributes | data: @png <> "changed"}) ==
             {:error, :input_artifact_source_conflict}
  end

  test "artifact validation matches Coop's bounded input contract" do
    base = %{
      data: "plain text",
      media_type: "text/plain",
      name: "notes.txt",
      source_kind: "slack",
      source_ref: "T123:F124"
    }

    assert {:ok, _artifact} = Artifacts.put(base)

    for {field, value} <- [
          data: <<0>>,
          media_type: "application/zip",
          name: "../notes.txt",
          source_kind: "Slack",
          source_ref: ""
        ] do
      assert {:error, {:invalid_input_artifact, ^field}} =
               base |> Map.put(field, value) |> Artifacts.put()
    end

    assert Artifacts.fetch_many(["artifact:input:missing"]) ==
             {:error, :input_artifact_not_found}

    assert Artifacts.put(:invalid) == {:error, {:invalid_input_artifact, :fields}}
    assert Artifacts.fetch_many(:invalid) == {:error, :input_artifact_not_found}
    assert Artifacts.fetch_many(["same", "same"]) == {:error, :input_artifact_not_found}
    assert Artifacts.maximum_bytes() == 8 * 1_024 * 1_024

    assert Artifacts.coop_inputs(["artifact:input:missing"]) ==
             {:error, :input_artifact_not_found}

    assert Artifacts.coop_inputs(Enum.map(1..6, &"artifact:input:#{&1}")) ==
             {:error, :input_artifact_bound_exceeded}
  end

  test "every Coop media family is checked against its actual bytes" do
    variants = [
      {"image/jpeg", "photo.jpg", <<255, 216, 255, 224>>},
      {"image/gif", "old.gif", "GIF87a-bytes"},
      {"image/gif", "new.gif", "GIF89a-bytes"},
      {"image/webp", "image.webp", <<"RIFF", 0, 0, 0, 0, "WEBP", 1>>},
      {"application/pdf", "report.pdf", "%PDF-1.7"},
      {"application/json", "data.json", ~s({"ok":true})}
    ]

    Enum.with_index(variants, fn {media_type, name, data}, index ->
      assert {:ok, artifact} =
               Artifacts.put(%{
                 data: data,
                 media_type: media_type,
                 name: name,
                 source_kind: "test",
                 source_ref: "media:#{index}"
               })

      assert {:ok, [loaded]} = Artifacts.coop_inputs([artifact.ref])
      assert loaded["data"] == data
    end)

    assert Artifacts.put(%{
             data: "not a pdf",
             media_type: "application/pdf",
             name: "bad.pdf",
             source_kind: "test",
             source_ref: "media:bad"
           }) == {:error, {:invalid_input_artifact, :data}}

    assert Artifacts.put(%{
             data: "text",
             media_type: "text/plain",
             name: nil,
             source_kind: "test",
             source_ref: "media:nil-name"
           }) == {:error, {:invalid_input_artifact, :name}}
  end

  test "a frozen Work submission takes relational custody of every input artifact" do
    suffix = Ecto.UUID.generate()

    assert {:ok, artifact} =
             Artifacts.put(%{
               data: "evidence #{suffix}",
               media_type: "text/plain",
               name: "evidence.txt",
               source_kind: "test",
               source_ref: "work-custody:#{suffix}"
             })

    episode_id = Ecto.UUID.generate()
    turn_ref = "input-artifact-custody:turn:#{suffix}"

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "input-artifact-custody:#{suffix}",
                 native_input_id: "input-artifact-custody:source:#{suffix}",
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("input-artifact-custody:worker:#{suffix}", 60)

    assert {:ok, submission} =
             Submission.new(
               %{"request" => "Use the exact attached evidence."},
               "Use the exact attached evidence.",
               %{"type" => "object"},
               "work-final-live-v3",
               [artifact.ref]
             )

    assert {:ok, frozen} =
             Custody.freeze_submission(episode_id, turn_ref, claim.lease_ref, submission)

    assert Repo.query!(
             "SELECT artifact_id FROM work_input_artifact_references WHERE turn_id = $1",
             [Ecto.UUID.dump!(frozen.id)]
           ).rows == [[Ecto.UUID.dump!(artifact.id)]]
  end

  test "inbox artifact custody rejects missing, forged, and contradictory descriptors" do
    suffix = Ecto.UUID.generate()

    assert {:ok, artifact} =
             Artifacts.put(%{
               data: "trusted #{suffix}",
               media_type: "text/plain",
               name: "trusted.txt",
               source_kind: "slack",
               source_ref: "T-artifacts:F-#{suffix}"
             })

    descriptor = input_descriptor(artifact)

    assert Inbox.record(input_with_files!([%{descriptor | "bytes" => artifact.byte_size + 1}])) ==
             {:error, {:invalid_input_artifact_reference, :identity}}

    assert Inbox.record(
             input_with_files!([
               %{
                 descriptor
                 | "artifact_ref" => "artifact:input:missing",
                   "sha256" => String.duplicate("f", 64)
               }
             ])
           ) == {:error, :input_artifact_not_found}

    assert Inbox.record(
             input_with_files!([descriptor, %{descriptor | "name" => "contradiction.txt"}])
           ) == {:error, {:invalid_input_artifact_reference, :descriptor_conflict}}

    assert Inbox.record(input_with_files!([descriptor], "webhook")) ==
             {:error, {:invalid_input_artifact_reference, :identity}}

    assert {:ok, %{entry: duplicate_descriptor_entry}} =
             Inbox.record(input_with_files!([descriptor, descriptor]))

    assert Repo.query!(
             "SELECT count(*) FROM ingress_input_artifact_references WHERE input_id = $1",
             [Ecto.UUID.dump!(duplicate_descriptor_entry.id)]
           ).rows == [[1]]

    assert References.attach_input(:invalid, Ecto.UUID.generate()) ==
             {:error, {:invalid_input_artifact_reference, :input}}

    assert References.attach_turn(nil, []) ==
             {:error, {:invalid_input_artifact_reference, :refs}}

    assert Repo.transaction(fn ->
             References.attach_turn(Ecto.UUID.generate(), [artifact.ref, artifact.ref])
           end) == {:ok, {:error, {:invalid_input_artifact_reference, :refs}}}

    assert Repo.transaction(fn ->
             References.attach_turn(Ecto.UUID.generate(), ["not-an-artifact-ref"])
           end) == {:ok, {:error, {:invalid_input_artifact_reference, :ref}}}

    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 1
  end

  test "accepted output images are exact, ordered, and idempotent" do
    turn_id = output_turn!("accepted")

    bodies = [
      output("chart.png", "image/png", @png),
      output("photo.jpg", "image/jpeg", <<255, 216, 255, 224>>),
      output("old.gif", "image/gif", "GIF87a-bytes"),
      output("new.gif", "image/gif", "GIF89a-bytes"),
      output("plot.webp", "image/webp", <<"RIFF", 0, 0, 0, 0, "WEBP", 1>>)
    ]

    metadata = Enum.map(bodies, &Map.drop(&1, ["data"]))
    assert {:ok, ^metadata} = Outputs.prepare_metadata(metadata)
    assert Outputs.refs(metadata) == Enum.map(metadata, & &1["id"])

    assert {:ok, stored} = Outputs.put_many(turn_id, bodies)
    assert Enum.map(stored, & &1.ref) == Outputs.refs(metadata)

    assert {:ok, duplicates} = Outputs.put_many(turn_id, bodies)
    assert Enum.map(duplicates, & &1.id) == Enum.map(stored, & &1.id)

    requested = metadata |> Outputs.refs() |> Enum.reverse()
    assert {:ok, fetched} = Outputs.fetch_many(turn_id, requested)
    assert Enum.map(fetched, & &1.ref) == requested
    assert Enum.map(fetched, & &1.data) == Enum.reverse(Enum.map(bodies, & &1["data"]))
    assert {:ok, []} = Outputs.fetch_many(turn_id, [])
  end

  test "output artifact metadata and bodies reject every ambiguous identity" do
    turn_id = output_turn!("invalid")
    png = output("chart.png", "image/png", @png)
    metadata = Map.drop(png, ["data"])

    assert Outputs.prepare_metadata(:invalid) ==
             {:error, {:invalid_work_output_artifacts, :metadata}}

    assert Outputs.prepare_metadata(List.duplicate(metadata, 6)) ==
             {:error, {:invalid_work_output_artifacts, :metadata}}

    assert Outputs.prepare_metadata([metadata, metadata]) ==
             {:error, {:invalid_work_output_artifacts, :metadata}}

    same_sha = %{metadata | "id" => "different-ref"}

    assert Outputs.prepare_metadata([metadata, same_sha]) ==
             {:error, {:invalid_work_output_artifacts, :metadata}}

    oversized = %{metadata | "bytes" => 4 * 1_024 * 1_024 + 1}

    assert Outputs.prepare_metadata([
             %{oversized | "id" => "large-one", "sha256" => String.duplicate("a", 64)},
             %{oversized | "id" => "large-two", "sha256" => String.duplicate("b", 64)}
           ]) == {:error, {:invalid_work_output_artifacts, :metadata}}

    for invalid <- [
          nil,
          Map.put(metadata, "extra", true),
          %{metadata | "id" => "bad ref"},
          %{metadata | "name" => nil},
          %{metadata | "name" => "."},
          %{metadata | "name" => "../chart.png"},
          %{metadata | "name" => "chart\n.png"},
          %{metadata | "media_type" => "text/plain"},
          %{metadata | "sha256" => "bad"},
          %{metadata | "bytes" => 0}
        ] do
      assert Outputs.prepare_metadata([invalid]) ==
               {:error, {:invalid_work_output_artifacts, :metadata}}
    end

    assert Outputs.put_many("bad-turn", [png]) ==
             {:error, {:invalid_work_output_artifacts, :bodies}}

    assert Outputs.put_many(turn_id, :invalid) ==
             {:error, {:invalid_work_output_artifacts, :bodies}}

    assert Outputs.put_many(turn_id, List.duplicate(png, 6)) ==
             {:error, {:invalid_work_output_artifacts, :bodies}}

    for invalid <- [
          nil,
          %{png | "data" => @png <> "changed"},
          %{png | "sha256" => String.duplicate("a", 64)},
          %{png | "media_type" => "image/jpeg"}
        ] do
      assert Outputs.put_many(turn_id, [invalid]) ==
               {:error, {:invalid_work_output_artifacts, :bodies}}
    end

    assert {:ok, [_stored]} = Outputs.put_many(turn_id, [png])

    conflicting =
      output("different.png", "image/png", @png <> "different")
      |> Map.put("id", png["id"])

    assert {:error, {:work_output_artifact_conflict, %Ecto.Changeset{}}} =
             Outputs.put_many(turn_id, [conflicting])

    assert Outputs.fetch_many("bad-turn", []) == {:error, :work_output_artifact_not_found}
    assert Outputs.fetch_many(turn_id, :invalid) == {:error, :work_output_artifact_not_found}

    assert Outputs.fetch_many(turn_id, [png["id"], png["id"]]) ==
             {:error, :work_output_artifact_not_found}

    assert Outputs.fetch_many(turn_id, ["bad ref"]) ==
             {:error, :work_output_artifact_not_found}

    assert Outputs.fetch_many(turn_id, Enum.map(1..6, &"missing-#{&1}")) ==
             {:error, :work_output_artifact_not_found}

    assert Outputs.fetch_many(turn_id, ["missing"]) ==
             {:error, :work_output_artifact_not_found}
  end

  defp output(name, media_type, data) do
    sha256 = digest(data)

    %{
      "bytes" => byte_size(data),
      "data" => data,
      "id" => "artifact-#{binary_part(sha256, 0, 24)}",
      "media_type" => media_type,
      "name" => name,
      "sha256" => sha256
    }
  end

  defp input_with_files!(files, source_kind \\ "slack") do
    suffix = Ecto.UUID.generate()

    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U-artifacts"},
               content: %{"files" => files, "text" => "Inspect the exact attachment."},
               destination: %{
                 conversation_ref: "#{source_kind}:T-artifacts:C-artifacts",
                 thread_ref: "1788000000.000001",
                 transport: source_kind
               },
               event_kind: :message,
               event_ref: "artifact-input:#{suffix}",
               native_input_id: "artifact-input:#{suffix}",
               occurred_at: ~U[2026-08-29 12:00:00.000000Z],
               occurred_at_source: :source,
               revision: 1,
               source: %{kind: source_kind, ref: "T-artifacts"},
               source_capabilities: %{"react" => %{"emoji_names" => nil}},
               source_item_ref: "1788000000.000001"
             })

    input
  end

  defp input_descriptor(artifact) do
    %{
      "artifact_ref" => artifact.ref,
      "bytes" => artifact.byte_size,
      "media_type" => artifact.media_type,
      "name" => artifact.name,
      "sha256" => artifact.sha256,
      "status" => "available"
    }
  end

  defp output_turn!(suffix) do
    episode_id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: episode_id,
        episode_key: "output-artifacts:#{suffix}:#{episode_id}",
        native_input_id: "output-artifacts:source:#{suffix}:#{episode_id}",
        turn_ref: "output-artifacts:turn:#{suffix}:#{episode_id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("output-artifacts:worker:#{suffix}", 60, :work)
    claim.turn.id
  end

  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
