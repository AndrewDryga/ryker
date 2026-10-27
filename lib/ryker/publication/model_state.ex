defmodule Ryker.Publication.ModelState do
  @moduledoc "Bounded canonical publication evidence, separately scoped as own custody or context."
  alias Ryker.Episodes
  alias Ryker.Publication.{Followup, Publication, Receipt, Review}
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work

  # A count without the saved diagnostics made a blocked task ask a person to
  # relay its own review. These bounded Coop fields explain the refusal; they
  # do not grant approval or expose the patch, task body or delivery credentials.
  @review_fields ~w(candidate_head candidate_tree gate gate_error not_publishable_reasons policy_findings publishable rebase session_revision)
  @receipt_fields ~w(branch_ref candidate_tree commit_sha pull_request_number pull_request_url repository)

  @spec snapshot(Ecto.UUID.t(), String.t() | nil) :: map() | nil
  def snapshot(episode_id, repository) when is_binary(repository) do
    case Repo.peek(Publication.Query.model_state(episode_id, repository)) do
      {%Publication{} = publication, followup} ->
        publication
        |> document(followup)
        |> Map.put(
          "newer_implementation_recorded",
          Review.stale_work?(
            publication,
            Records.plan_from_records(Records.goal_records(episode_id))
          )
        )

      nil ->
        nil
    end
  end

  def snapshot(_episode_id, _repository), do: nil

  @doc "Host operational metadata only; a confirmed same-thread task grants no new authority."
  @spec related(Episodes.Episode.t(), Work.Session.t()) :: [map()]
  def related(%Episodes.Episode{} = episode, %Work.Session{} = session) do
    episode
    |> Publication.Query.related_model_states(readable_repositories(session))
    |> Repo.all()
    |> Enum.map(fn {publication, followup, source_episode_id, offer_ref} ->
      publication
      |> document(followup)
      |> Map.merge(%{
        "context_only" => true,
        "source_episode_ref" => "episode:#{source_episode_id}",
        "source_offer_ref" => offer_ref
      })
    end)
  end

  defp readable_repositories(session) do
    case Work.RepositoryContext.restore(session.repository_context, session.repository_ref) do
      {:ok, nil} -> List.wrap(session.repository_ref)
      {:ok, context} -> [context.primary_repository | context.read_only_repositories]
      {:error, :invalid} -> []
    end
  end

  # Never reuse record/goal text for linked context. These are host custody fields,
  # not a source-backed summary, transcript, authority grant or current GitHub read.
  defp document(publication, followup) do
    %{
      "existing_pull_request" => existing_pull_request(publication),
      "followup" => followup_document(followup),
      "published_at" => datetime(publication.published_at),
      "published_revision" => published_revision(publication),
      "ref" => publication.ref,
      "repository" => publication.repository,
      "review" => review_document(publication),
      "review_generation" => publication.review_generation,
      "status" => Atom.to_string(publication.status)
    }
  end

  defp published_revision(%Publication{publication_receipt: %{} = receipt} = publication) do
    if receipt["repository"] == publication.repository and
         Receipt.fingerprint(receipt) == publication.publication_receipt_fingerprint,
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
    if Review.fingerprint(review) == publication.review_fingerprint do
      review
      |> Map.take(@review_fields)
      |> Map.put("policy_findings_count", length(review["policy_findings"] || []))
      |> Map.put("reviewed_at", datetime(publication.reviewed_at))
    end
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
