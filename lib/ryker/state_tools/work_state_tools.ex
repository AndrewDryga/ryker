defmodule Ryker.StateTools.WorkStateTools do
  @moduledoc false
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery
  alias Ryker.Knowledge
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work

  # The newest records within the limit: the oldest kept the latest evidence
  # and waits of a long episode out of reach (2026-10-04 review).
  @spec get_work_state(map(), map()) :: {:ok, map()} | {:error, term()}
  def get_work_state(%{"limit" => limit}, binding) do
    records =
      Records.model_records(binding.episode, binding.session.repository_ref)
      |> Enum.take(-limit)

    platform_actions = Delivery.PlatformActionCustody.model_actions(binding.episode.id)

    with :ok <-
           Knowledge.KnowledgeSnapshot.expose(
             binding,
             Enum.map(records, &Records.DerivedContext.record/1)
           ) do
      {:ok,
       %{
         "cursor" => "episode:#{binding.episode.id}:v#{binding.episode.semantic_version}",
         "episode" => %{
           "episode_ref" => binding.episode.key,
           "owner" => Atom.to_string(binding.episode.owner_kind),
           "state" => Atom.to_string(binding.episode.state)
         },
         "platform_actions" => platform_actions,
         "records" => records
       }}
    end
  end

  @spec validate_final(map(), map()) :: {:ok, map()} | {:error, term()}
  def validate_final(%{"candidate" => candidate}, binding) do
    candidate_json = CanonicalJSON.encode!(candidate)
    candidate_sha256 = Work.FinalPreflight.candidate_sha256(candidate)
    artifact_refs = get_in(candidate, ["outcome", "artifact_refs"]) || []
    validation_context = validation_context(binding, artifact_refs)

    ledger_sha256 =
      Work.FinalPreflight.ledger_sha256(
        binding.episode.id,
        binding.episode.semantic_version,
        artifact_refs,
        binding.turn.id
      )

    # Coop derives output artifact identities while it is completing the
    # provider turn. Those bytes cannot exist in Ryker before this
    # in-turn preflight. FinalPreflight excludes only those late-issued refs;
    # the terminal Work validator requires every ref in Coop's exact manifest,
    # then fetches and digest-checks the bytes before accepting the result or
    # creating delivery custody.
    with {:accept, %{final: final}} <-
           Work.Validator.validate(candidate_json, validation_context, Repo.now!()),
         :ok <- Delivery.Presentation.validate(binding.episode, binding.turn, final),
         {:ok, _turn} <-
           Work.Custody.record_final_preflight(
             binding.episode.id,
             binding.turn.turn_ref,
             binding.turn.lease_ref,
             candidate_sha256,
             ledger_sha256,
             binding.episode.semantic_version
           ) do
      {:ok,
       %{
         "accepted" => true,
         "candidate" => Work.Final.document(final),
         "candidate_sha256" => candidate_sha256,
         "ledger_version" => binding.episode.semantic_version
       }}
    else
      {:reject, violations} ->
        {:ok, %{"accepted" => false, "violations" => violations}}

      {:error, {:invalid_delivery_presentation, reason}} ->
        {:ok,
         %{
           "accepted" => false,
           "violations" => [Work.Validator.presentation_violation(reason)]
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The executor's own context, with the artifacts the answer names: the
  # preflight never asks for more than the executor will.
  defp validation_context(binding, artifact_refs) do
    binding.episode
    |> Work.ValidationContext.build(binding.turn)
    |> Map.merge(%{
      "artifact_metadata" => Enum.map(artifact_refs, &%{"id" => &1, "name" => &1}),
      "artifact_refs" => artifact_refs
    })
  end
end
