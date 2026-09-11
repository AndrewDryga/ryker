defmodule Responder.Publication.Card do
  @moduledoc false

  alias Responder.Publication.{Publication, Review}

  @review_fields ~w(candidate_tree draft_authorized gate patch_bytes patch_digest policy_findings publishable reasons rebase repository title)
  @result_fields ~w(branch_ref commit_sha pull_request_number pull_request_url repository title)

  @doc """
  Projects one trusted review verdict, saying whether Responder opens the draft.

  `draft_authorized?` is the host's own answer, never the model's: when it is
  true the publication already carries the confirming person's grant, so the
  card states what is happening instead of asking for a click that changes
  nothing.
  """
  def review(%Publication{review_document: review} = publication, draft_authorized?)
      when is_map(review) and is_boolean(draft_authorized?) do
    reasons = review["not_publishable_reasons"]

    %{
      "kind" => "publication_review",
      "payload" => %{
        "candidate_tree" => review["candidate_tree"],
        "draft_authorized" => draft_authorized?,
        "gate" => review["gate"],
        "patch_bytes" => review["patch_bytes"],
        "patch_digest" => review["patch_digest"],
        "policy_findings" => review["policy_findings"],
        "publishable" => Review.publishable?(review),
        "reasons" => reasons,
        "rebase" => review["rebase"],
        "repository" => publication.repository,
        "title" => publication.title
      },
      "ref" => publication.ref,
      "status" => "open"
    }
  end

  def published(%Publication{publication_receipt: receipt} = publication) when is_map(receipt) do
    %{
      "kind" => "publication_result",
      "payload" => %{
        "branch_ref" => receipt["branch_ref"],
        "commit_sha" => receipt["commit_sha"],
        "pull_request_number" => receipt["pull_request_number"],
        "pull_request_url" => receipt["pull_request_url"],
        "repository" => publication.repository,
        "title" => publication.title
      },
      "ref" => publication.ref,
      "status" => "confirmed"
    }
  end

  def prepare_record(
        %{"kind" => "publication_review", "payload" => payload, "ref" => ref, "status" => "open"} =
          record
      )
      when map_size(record) == 4 do
    with true <- reference?(ref),
         true <- is_map(payload) and Map.keys(payload) |> Enum.sort() == @review_fields,
         true <- bounded_text?(payload["title"], 120),
         true <- bounded_text?(payload["repository"], 256),
         true <- git_identity?(payload["candidate_tree"]),
         true <- payload["gate"] in ~w(passed failed startup_error not_run none),
         true <- payload["rebase"] in ~w(clean conflict),
         true <- is_integer(payload["patch_bytes"]) and payload["patch_bytes"] >= 0,
         true <- optional_digest?(payload["patch_digest"]),
         true <- is_boolean(payload["publishable"]),
         true <- is_boolean(payload["draft_authorized"]),
         true <- bounded_list?(payload["policy_findings"], 64, 4_096),
         true <- bounded_list?(payload["reasons"], 64, 256) do
      {:ok, payload}
    else
      false -> {:error, {:invalid_publication_card, :review}}
    end
  end

  def prepare_record(
        %{
          "kind" => "publication_result",
          "payload" => payload,
          "ref" => ref,
          "status" => "confirmed"
        } = record
      )
      when map_size(record) == 4 do
    with true <- reference?(ref),
         true <- is_map(payload) and Map.keys(payload) |> Enum.sort() == @result_fields,
         true <- bounded_text?(payload["title"], 120),
         true <- bounded_text?(payload["repository"], 256),
         true <- bounded_text?(payload["branch_ref"], 256),
         true <- git_identity?(payload["commit_sha"]),
         true <- is_integer(payload["pull_request_number"]) and payload["pull_request_number"] > 0,
         true <- bounded_text?(payload["pull_request_url"], 2_048) do
      {:ok, payload}
    else
      false -> {:error, {:invalid_publication_card, :result}}
    end
  end

  def prepare_record(_record), do: {:error, {:invalid_publication_card, :record}}

  defp reference?(value),
    do: is_binary(value) and Regex.match?(~r/\Apublication:[A-Za-z0-9_.:-]{1,240}\z/, value)

  defp git_identity?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{40,64}\z/, value)

  defp optional_digest?(nil), do: true
  defp optional_digest?(value), do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{64}\z/, value)

  defp bounded_list?(values, count, bytes) when is_list(values) and length(values) <= count,
    do: Enum.all?(values, &bounded_text?(&1, bytes))

  defp bounded_list?(_values, _count, _bytes), do: false

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end
end
