defmodule Ryker.Publication.ConflictReceipt do
  @moduledoc """
  Validates the exact remote identity observed during a recoverable publication race.

  The configured GitHub client first proves that the branch belongs to the
  Ryker App. Custody then revalidates this bounded receipt before using its
  observed head as the operator update's compare-and-swap fence.
  """

  @fields ~w(branch_ref candidate_commit_sha github_repository observed_head_sha pull_request_number pull_request_url repository)

  @spec prepare(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(%{} = receipt, expected_repository) do
    with true <- Enum.sort(Map.keys(receipt)) == Enum.sort(@fields),
         true <- receipt["repository"] == expected_repository,
         true <- repository?(receipt["github_repository"]),
         true <- branch_ref?(receipt["branch_ref"]),
         true <- git_identity?(receipt["candidate_commit_sha"]),
         true <- git_identity?(receipt["observed_head_sha"]),
         true <- receipt["candidate_commit_sha"] != receipt["observed_head_sha"],
         true <- is_integer(receipt["pull_request_number"]) and receipt["pull_request_number"] > 0,
         true <- exact_pull_url?(receipt) do
      {:ok, receipt}
    else
      false -> {:error, {:invalid_publication_conflict_receipt, :identity}}
    end
  end

  def prepare(_receipt, _expected_repository),
    do: {:error, {:invalid_publication_conflict_receipt, :document}}

  defp repository?(value),
    do: is_binary(value) and Regex.match?(~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/, value)

  defp branch_ref?(value),
    do:
      is_binary(value) and
        Regex.match?(~r/\Arefs\/heads\/[A-Za-z0-9._\/-]{1,240}\z/, value)

  defp git_identity?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-f0-9]{40}([a-f0-9]{24})?\z/, value)

  defp exact_pull_url?(receipt) do
    receipt["pull_request_url"] ==
      "https://github.com/#{receipt["github_repository"]}/pull/#{receipt["pull_request_number"]}"
  end
end
