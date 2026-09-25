defmodule Ryker.Work.FinalPreflight do
  @moduledoc false

  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.PlatformActionCustody
  alias Ryker.State.Records

  # A missing title and a null one both keep the episode's name, so they are
  # the same candidate: a model that preflights without the key and returns the
  # schema's explicit null is not sent back to preflight again.
  @spec candidate_sha256(map()) :: String.t()
  def candidate_sha256(candidate) when is_map(candidate) do
    candidate
    |> Map.put_new("title", nil)
    |> normalize_output_artifact_refs()
    |> CanonicalJSON.digest()
  end

  @spec ledger_sha256(Ecto.UUID.t(), non_neg_integer(), [String.t()], Ecto.UUID.t() | nil) ::
          String.t()
  def ledger_sha256(episode_id, semantic_version, artifact_refs, turn_id \\ nil)
      when is_binary(episode_id) and is_integer(semantic_version) and semantic_version >= 0 and
             is_list(artifact_refs) do
    CanonicalJSON.digest(%{
      "episode_semantic_version" => semantic_version,
      "output_artifacts" => "validated_from_coop_terminal_manifest",
      "records" =>
        Map.merge(
          Records.validation_records(episode_id),
          PlatformActionCustody.validation_records(episode_id, turn_id)
        )
    })
  end

  # The provider knows only the saved filename while it is still inside the
  # turn. Coop derives the immutable artifact ID from the bytes when that
  # prompt ends. The terminal validator binds every returned ID to Coop's exact
  # manifest and digest-checks the bytes, so the in-turn preflight deliberately
  # covers every final field except this one late host-issued identity.
  defp normalize_output_artifact_refs(
         %{"outcome" => %{"artifact_refs" => refs} = outcome} = candidate
       )
       when is_list(refs) do
    %{candidate | "outcome" => %{outcome | "artifact_refs" => []}}
  end

  defp normalize_output_artifact_refs(candidate), do: candidate
end
