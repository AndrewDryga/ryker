defmodule Ryker.Publication.Receipt do
  @moduledoc false

  alias Ryker.CanonicalJSON

  @fields ~w(branch_ref candidate_tree commit_sha pull_request_number pull_request_url repository)
  @git_identity ~r/\A[a-f0-9]{40}([a-f0-9]{24})?\z/
  @branch ~r/\Arefs\/heads\/[A-Za-z0-9._\/-]{1,240}\z/

  @spec prepare(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(receipt, review, repository)
      when is_map(receipt) and is_map(review) and is_binary(repository) do
    with true <- Map.keys(receipt) |> Enum.sort() == @fields,
         true <- receipt["repository"] == repository,
         true <- receipt["candidate_tree"] == review["candidate_tree"],
         true <- receipt["commit_sha"] == review["candidate_head"],
         true <- is_binary(receipt["branch_ref"]) and Regex.match?(@branch, receipt["branch_ref"]),
         true <- git_identity?(receipt["commit_sha"]),
         true <- is_integer(receipt["pull_request_number"]) and receipt["pull_request_number"] > 0,
         true <- pull_url?(receipt["pull_request_url"], receipt["pull_request_number"]),
         :ok <- CanonicalJSON.validate(receipt, max_bytes: 16 * 1_024) do
      {:ok, receipt}
    else
      false -> {:error, {:invalid_publication_receipt, :identity}}
      {:error, _reason} -> {:error, {:invalid_publication_receipt, :document}}
    end
  end

  def prepare(_receipt, _review, _repository),
    do: {:error, {:invalid_publication_receipt, :document}}

  def fingerprint(receipt), do: receipt |> CanonicalJSON.encode!() |> digest()

  defp git_identity?(value), do: is_binary(value) and Regex.match?(@git_identity, value)

  # The link opens the pull request the receipt names. Its owner and
  # repository are GitHub's own, and the publication keeps them: a worker can
  # write only to the repository its grant names, and a renamed repository's
  # link names it as it is now.
  defp pull_url?(value, number) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: "github.com", path: path, query: nil, fragment: nil}}
      when is_binary(path) ->
        Regex.match?(~r/\A\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/#{number}\z/, path)

      _invalid ->
        false
    end
  end

  defp pull_url?(_value, _number), do: false
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
