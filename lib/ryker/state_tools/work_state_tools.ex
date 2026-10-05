defmodule Ryker.StateTools.WorkStateTools do
  @moduledoc false

  alias Ryker.Artifacts.Outputs
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.{PlatformActionCustody, Presentation}
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Records
  alias Ryker.Records.DerivedContext
  alias Ryker.Work.{Custody, Final, FinalPreflight, Validator}

  # The newest records within the limit: the oldest kept the latest evidence
  # and waits of a long episode out of reach (2026-10-04 review).
  @spec get_work_state(map(), map()) :: {:ok, map()} | {:error, term()}
  def get_work_state(%{"limit" => limit}, binding) do
    records =
      Records.model_records(binding.episode, binding.session.repository_ref)
      |> Enum.take(-limit)

    platform_actions = PlatformActionCustody.model_actions(binding.episode.id)

    with :ok <-
           KnowledgeSnapshot.expose(
             binding,
             Enum.map(records, &DerivedContext.record/1)
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
    candidate_sha256 = FinalPreflight.candidate_sha256(candidate)
    artifact_refs = get_in(candidate, ["outcome", "artifact_refs"]) || []
    validation_context = validation_context(binding, artifact_refs)

    ledger_sha256 =
      FinalPreflight.ledger_sha256(
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
           Validator.validate(candidate_json, validation_context, DateTime.utc_now()),
         :ok <- Presentation.validate(binding.episode, binding.turn, final),
         {:ok, _turn} <-
           Custody.record_final_preflight(
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
         "candidate" => Final.document(final),
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
           "violations" => [presentation_violation(reason)]
         }}

      {:error, _reason} = error ->
        error
    end
  end

  defp presentation_violation(reason) do
    "The final response cannot be rendered safely for this destination: #{inspect(reason, limit: 8, printable_limit: 256)}"
  end

  defp validation_context(binding, artifact_refs) do
    %{
      "artifact_delivery_supported" => Outputs.delivery_supported?(binding.episode),
      "artifact_metadata" => Enum.map(artifact_refs, &%{"id" => &1, "name" => &1}),
      "artifact_refs" => artifact_refs,
      "execution_mode" => Atom.to_string(binding.episode.execution_mode),
      "open_required_goals" => Records.open_required_goals(binding.episode.id),
      "records" => validation_records(binding.episode.id, binding.turn.id),
      "slack_mentions" => Custody.Delivery.answer_mentions(binding.episode, binding.turn),
      "visible_reply_required" => true,
      "workspace" => nil
    }
  end

  defp validation_records(episode_id, turn_id) do
    Map.merge(
      Records.validation_records(episode_id),
      PlatformActionCustody.validation_records(episode_id, turn_id)
    )
  end
end
