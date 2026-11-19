defmodule Ryker.Work.ValidationSnapshot do
  @moduledoc false
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work.{GuidanceRequirements, Turn}

  @spec ledger_sha256(Ecto.UUID.t(), non_neg_integer(), Ecto.UUID.t()) :: String.t()
  def ledger_sha256(episode_id, semantic_version, turn_id) do
    CanonicalJSON.digest(%{
      "episode_semantic_version" => semantic_version,
      "guidance_requirements" => guidance_requirements(turn_id),
      "open_required_goals" => Records.open_required_goals(episode_id),
      "output_artifacts" => "validated_from_turn_artifact_manifests",
      "records" =>
        Map.merge(
          validation_records(episode_id, turn_id),
          Delivery.PlatformActionCustody.validation_records(episode_id, turn_id)
        )
    })
  end

  defp validation_records(episode_id, turn_id) do
    records = Records.validation_records(episode_id)
    # This host-owned handoff is created after the worker completes, before
    # result acceptance. It grants no model authority and cannot invalidate
    # the answer that caused it. Earlier turns' offers remain in the snapshot.
    offer =
      turn_id
      |> Records.Record.Query.by_turn_id()
      |> Records.Record.Query.by_operation_id("host:publication:ready")
      |> Repo.fetch()

    case offer do
      {:error, :not_found} -> records
      {:ok, %Records.Record{kind: "publication_offer", ref: ref}} -> Map.delete(records, ref)
      {:ok, _other_kind} -> records
    end
  end

  defp guidance_requirements(turn_id) do
    case Repo.fetch(Turn.Query.by_id(turn_id)) do
      {:ok, turn} -> GuidanceRequirements.context(turn)
      {:error, :not_found} -> []
    end
  end
end
