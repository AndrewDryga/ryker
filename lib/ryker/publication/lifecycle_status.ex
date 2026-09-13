defmodule Ryker.Publication.LifecycleStatus do
  @moduledoc false

  @fields ~w(base_ref checks_failed checks_passed checks_state checks_total checks_url draft head_ref head_sha merge_sha merged merged_at number state url)
  @git_identity ~r/\A[a-f0-9]{40}([a-f0-9]{24})?\z/

  @spec prepare(map()) :: {:ok, map()} | {:error, term()}
  def prepare(%{} = status) do
    with true <- Map.keys(status) |> Enum.sort() == @fields,
         true <- status["state"] in ~w(open closed),
         true <- status["checks_state"] in ~w(none pending passing failing),
         true <- is_boolean(status["draft"]) and is_boolean(status["merged"]),
         true <- positive(status["number"]),
         true <- git_identity(status["head_sha"]),
         true <- reference(status["head_ref"], 240),
         true <- reference(status["base_ref"], 240),
         true <- github_url(status["url"]),
         true <- github_url(status["checks_url"]),
         true <- counts(status),
         :ok <- merge(status) do
      {:ok, status}
    else
      false -> {:error, {:invalid_publication_lifecycle_status, :document}}
      {:error, _reason} = error -> error
    end
  end

  def prepare(_status), do: {:error, {:invalid_publication_lifecycle_status, :document}}

  defp merge(%{"merged" => false, "merge_sha" => nil, "merged_at" => nil}), do: :ok

  defp merge(%{"merged" => true, "merge_sha" => sha, "merged_at" => at}) do
    with true <- git_identity(sha),
         {:ok, _datetime, 0} <- DateTime.from_iso8601(at || "") do
      :ok
    else
      _invalid -> {:error, {:invalid_publication_lifecycle_status, :merge}}
    end
  end

  defp merge(_status), do: {:error, {:invalid_publication_lifecycle_status, :merge}}

  defp counts(status) do
    total = status["checks_total"]
    passed = status["checks_passed"]
    failed = status["checks_failed"]

    Enum.all?([total, passed, failed], &(is_integer(&1) and &1 >= 0)) and
      passed + failed <= total
  end

  defp github_url(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: "github.com", path: path}} ->
        is_binary(path) and path != ""

      _invalid ->
        false
    end
  end

  defp github_url(_value), do: false
  defp git_identity(value), do: is_binary(value) and Regex.match?(@git_identity, value)
  defp positive(value), do: is_integer(value) and value > 0

  defp reference(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end
end
