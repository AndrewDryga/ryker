defmodule Ryker.ControlPlane.EpisodeTrace.Attachments do
  @moduledoc "Selected files of retained, accepted and delivered replies, without loading their bytes."
  alias Ryker.Artifacts
  alias Ryker.ControlPlane.Paths
  alias Ryker.Episodes
  alias Ryker.InspectionRedactor
  alias Ryker.Reference
  alias Ryker.Repo

  @maximum_replies 20
  @maximum_files 5

  def by_turn(%Episodes.Episode{} = episode, turns) do
    selected =
      turns
      |> Enum.filter(fn turn ->
        turn.episode_id == episode.id and not is_nil(turn.accepted_at) and
          not is_nil(turn.delivered_at) and is_nil(turn.operational_pruned_at)
      end)
      |> Enum.take(-@maximum_replies)
      |> Map.new(&{&1.id, selected_refs(&1.delivery_document)})

    refs = selected |> Map.values() |> List.flatten() |> Enum.uniq()
    listings = listings(Map.keys(selected), refs)
    conversation_id = conversation_id(episode)
    secrets = InspectionRedactor.configured_secrets()

    Map.new(selected, fn {turn_id, refs} ->
      attachments =
        refs
        |> Enum.map(&Map.get(listings, {turn_id, &1}))
        |> Enum.reject(&is_nil/1)
        |> Enum.map(&attachment(&1, conversation_id, secrets))

      {turn_id, attachments}
    end)
  end

  defp selected_refs(%{"outcome" => %{"artifact_refs" => refs}}) when is_list(refs),
    do: refs |> Enum.filter(&Reference.token?/1) |> Enum.uniq() |> Enum.take(@maximum_files)

  defp selected_refs(_document), do: []

  defp listings(_turn_ids, []), do: %{}

  defp listings(turn_ids, refs) do
    turn_ids
    |> Artifacts.OutputArtifact.Query.by_turn_ids()
    |> Artifacts.OutputArtifact.Query.by_refs(refs)
    |> Artifacts.OutputArtifact.Query.ordered_by_name()
    |> Artifacts.OutputArtifact.Query.limit_to(@maximum_replies * @maximum_files)
    |> Artifacts.OutputArtifact.Query.select_listing()
    |> Repo.all()
    |> Map.new(&{{&1.turn_id, &1.ref}, &1})
  end

  # Reuse the existing exact Chat/turn endpoint. Other transports show metadata
  # only; an episode read never creates a new media or worker-filesystem route.
  defp conversation_id(%Episodes.Episode{
         destination_transport: "control_plane",
         destination_conversation_ref: "control-plane:lab:" <> id = ref,
         destination_thread_ref: ref
       }) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp conversation_id(_episode), do: nil

  defp attachment(artifact, conversation_id, secrets) do
    %{
      bytes: artifact.byte_size,
      media_type: artifact.media_type,
      name:
        InspectionRedactor.artifact(artifact.name, secrets: secrets, max_bytes: 255).text ||
          "Generated file",
      path: conversation_id && Paths.artifact(conversation_id, artifact.turn_id, artifact.ref),
      ref: artifact.ref,
      status: "available"
    }
  end
end
