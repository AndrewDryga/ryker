defmodule Responder.Publication.Receipt do
  @moduledoc false

  alias Responder.CanonicalJSON

  @fields ~w(branch_ref candidate_tree commit_sha pull_request_number pull_request_url repository)
  @git_identity ~r/\A[a-f0-9]{40,64}\z/
  @branch ~r/\Arefs\/heads\/[A-Za-z0-9._\/-]{1,240}\z/

  @spec prepare(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(receipt, review, repository)
      when is_map(receipt) and is_map(review) and is_binary(repository) do
    with true <- Map.keys(receipt) |> Enum.sort() == @fields,
         true <- receipt["repository"] == repository,
         true <- receipt["candidate_tree"] == review["candidate_tree"],
         true <- is_binary(receipt["branch_ref"]) and Regex.match?(@branch, receipt["branch_ref"]),
         true <- git_identity?(receipt["commit_sha"]),
         true <- is_integer(receipt["pull_request_number"]) and receipt["pull_request_number"] > 0,
         true <- github_pull_url?(receipt["pull_request_url"]),
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

  defp github_pull_url?(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: "github.com", path: path}} ->
        is_binary(path) and
          Regex.match?(~r/\A\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*\z/, path)

      _invalid ->
        false
    end
  end

  defp github_pull_url?(_value), do: false
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
