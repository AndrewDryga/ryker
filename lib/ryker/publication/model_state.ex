defmodule Ryker.Publication.ModelState do
  @moduledoc "Bounded canonical publication evidence disclosed to the task's own model."
  alias Ryker.Publication.{Followup, Publication, Receipt, Review}
  alias Ryker.Records
  alias Ryker.Repo

  @review_fields ~w(candidate_head candidate_tree gate publishable session_revision)
  @receipt_fields ~w(branch_ref candidate_tree commit_sha pull_request_number pull_request_url repository)

  @spec snapshot(Ecto.UUID.t(), String.t() | nil) :: map() | nil
  def snapshot(episode_id, repository) when is_binary(repository) do
    case Repo.peek(Publication.Query.model_state(episode_id, repository)) do
      {%Publication{} = publication, followup} ->
        %{
          "existing_pull_request" => existing_pull_request(publication),
          "followup" => followup_document(followup),
          "newer_implementation_recorded" =>
            Review.stale_work?(
              publication,
              Records.plan_from_records(Records.goal_records(episode_id))
            ),
          "published_at" => datetime(publication.published_at),
          "published_revision" => published_revision(publication),
          "ref" => publication.ref,
          "repository" => publication.repository,
          "review" => review_document(publication),
          "review_generation" => publication.review_generation,
          "status" => Atom.to_string(publication.status)
        }

      nil ->
        nil
    end
  end

  def snapshot(_episode_id, _repository), do: nil

  defp published_revision(%Publication{publication_receipt: %{} = receipt} = publication) do
    if Receipt.fingerprint(receipt) == publication.publication_receipt_fingerprint,
      do: Map.take(receipt, @receipt_fields)
  end

  defp published_revision(_publication), do: nil

  # PR identity survives a re-review or conflict. It is not proof that the
  # candidate commit stored on that row has ever reached GitHub.
  defp existing_pull_request(%Publication{pull_request_number: number} = publication)
       when is_integer(number) do
    %{
      "number" => number,
      "repository" => publication.github_repository,
      "url" => publication.pull_request_url
    }
  end

  defp existing_pull_request(_publication), do: nil

  defp review_document(%Publication{review_document: %{} = review} = publication) do
    review
    |> Map.take(@review_fields)
    |> Map.put("policy_findings_count", length(review["policy_findings"] || []))
    |> Map.put("reviewed_at", datetime(publication.reviewed_at))
  end

  defp review_document(_publication), do: nil

  defp followup_document(%Followup{} = followup) do
    # Followup stores PR observations, not the checks' head SHA. Retaining
    # passing checks after re-review must not make a new candidate verified.
    %{
      "checks_apply_to_current_review_candidate" => "unknown",
      "checks_failed" => followup.checks_failed,
      "checks_for" => "last_observed_pull_request",
      "checks_passed" => followup.checks_passed,
      "checks_state" => Atom.to_string(followup.checks_state),
      "checks_total" => followup.checks_total,
      "merge_sha" => followup.merge_sha,
      "merged_at" => datetime(followup.merged_at),
      "pr_state" => Atom.to_string(followup.pr_state),
      "source" => "retained_github_followup"
    }
  end

  defp followup_document(_followup), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(nil), do: nil
end
