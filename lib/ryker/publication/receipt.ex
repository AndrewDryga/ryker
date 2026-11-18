defmodule Ryker.Publication.Receipt do
  @moduledoc false
  alias Ryker.CanonicalJSON
  alias Ryker.GitHub
  alias Ryker.GitObject
  alias Ryker.Maps

  @fields ~w(branch_ref candidate_tree commit_sha pull_request_number pull_request_url repository)

  @spec prepare(map(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def prepare(receipt, review, repository, target \\ nil)

  def prepare(receipt, review, repository, target)
      when is_map(receipt) and is_map(review) and is_binary(repository) do
    with true <- Maps.exact_keys?(receipt, @fields, ["target_observation"]),
         true <- target_observation?(receipt["target_observation"]),
         true <- target_matches?(receipt, target),
         true <- receipt["repository"] == repository,
         true <- receipt["candidate_tree"] == review["candidate_tree"],
         true <- receipt["commit_sha"] == review["candidate_head"],
         true <- GitObject.branch_ref?(receipt["branch_ref"]),
         true <- GitObject.id?(receipt["commit_sha"]),
         true <- is_integer(receipt["pull_request_number"]) and receipt["pull_request_number"] > 0,
         true <- pull_url?(receipt["pull_request_url"], receipt["pull_request_number"]),
         :ok <- CanonicalJSON.validate(receipt, max_bytes: 16 * 1_024) do
      {:ok, receipt}
    else
      false -> {:error, {:invalid_publication_receipt, :identity}}
      {:error, _reason} -> {:error, {:invalid_publication_receipt, :document}}
    end
  end

  def prepare(_receipt, _review, _repository, _target),
    do: {:error, {:invalid_publication_receipt, :document}}

  def fingerprint(receipt), do: CanonicalJSON.digest(receipt)

  defp target_matches?(receipt, nil), do: not Map.has_key?(receipt, "target_observation")

  defp target_matches?(receipt, %{"kind" => "existing_pull_request"} = target) do
    receipt["branch_ref"] == target["head_ref"] and
      receipt["pull_request_number"] == target["number"]
  end

  defp target_matches?(_receipt, _target), do: false

  defp target_observation?(nil), do: true

  defp target_observation?(%{} = observation) do
    Maps.exact_keys?(
      observation,
      ~w(state head_ref base_ref head_repository_id base_repository_id head_commit pull_request_state)
    ) and
      observation["state"] in ~w(changed_after_push unverified_after_push) and
      Enum.all?(~w(head_ref base_ref), &observed_ref?(observation[&1])) and
      Enum.all?(
        ~w(head_repository_id base_repository_id),
        &(is_integer(observation[&1]) and observation[&1] >= 0)
      ) and
      (observation["head_commit"] == "" or GitObject.id?(observation["head_commit"])) and
      observation["pull_request_state"] in ["", "open", "closed"]
  end

  defp target_observation?(_observation), do: false

  defp observed_ref?(value),
    do: is_binary(value) and String.valid?(value) and byte_size(value) <= 256

  # The link opens the pull request the receipt names. Its owner and
  # repository are GitHub's own, and the publication keeps them: a worker can
  # write only to the repository its grant names, and a renamed repository's
  # link names it as it is now.
  defp pull_url?(value, number) when is_binary(value) and byte_size(value) <= 2_048 do
    web_host = GitHub.web_host()

    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: ^web_host, path: path, query: nil, fragment: nil}}
      when is_binary(path) ->
        Regex.match?(~r/\A\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/#{number}\z/, path)

      _invalid ->
        false
    end
  end

  defp pull_url?(_value, _number), do: false
end
