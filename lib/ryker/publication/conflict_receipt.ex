defmodule Ryker.Publication.ConflictReceipt do
  @moduledoc """
  Validates the exact remote identity observed during a recoverable publication race.

  The configured GitHub client first proves that the branch belongs to the
  Ryker App. Custody then revalidates this bounded receipt before using its
  observed head as the operator update's compare-and-swap fence.
  """
  alias Ryker.GitHub
  alias Ryker.GitObject
  alias Ryker.Maps

  @fields ~w(branch_ref candidate_commit_sha github_repository observed_head_sha pull_request_number pull_request_url repository)

  @spec prepare(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(%{} = receipt, expected_repository) do
    with true <- Maps.exact_keys?(receipt, @fields),
         true <- receipt["repository"] == expected_repository,
         true <- GitHub.repository_name?(receipt["github_repository"]),
         true <- GitObject.branch_ref?(receipt["branch_ref"]),
         true <- GitObject.id?(receipt["candidate_commit_sha"]),
         true <- GitObject.id?(receipt["observed_head_sha"]),
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

  defp exact_pull_url?(receipt) do
    receipt["pull_request_url"] ==
      "#{GitHub.web_url()}/#{receipt["github_repository"]}/pull/#{receipt["pull_request_number"]}"
  end
end
