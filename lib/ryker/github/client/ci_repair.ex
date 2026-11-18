defmodule Ryker.GitHub.Client.CIRepair do
  @moduledoc "Fresh PR identity, complete labels and CI state for automatic repair eligibility."
  alias Ryker.GitHub
  alias Ryker.GitHub.Client.{Checks, Fields, Transport}
  alias Ryker.GitObject

  def snapshot(client, repository, repository_id, number) do
    with {:ok, pull} <- target(client, repository, repository_id, number),
         {:ok, checks} <- Checks.summary(client, repository, pull["head"]) do
      {:ok,
       Map.put(
         pull,
         "checks",
         Map.new(checks, fn {key, value} -> {Atom.to_string(key), value} end)
       )}
    end
  end

  @doc "Reads the identity and opt-out again immediately before publication."
  def target(client, repository, repository_id, number) do
    with :ok <- Fields.target(repository, number),
         {:ok, response} <-
           Transport.request(client, :get, "/repos/#{repository}/pulls/#{number}", nil),
         {:ok, pull} <- pull(response, repository_id, number),
         {:ok, labels} <- labels(client, repository, number, 1, []) do
      {:ok, Map.put(pull, "labels", labels)}
    end
  end

  @doc "Finds candidate PRs for check events whose payload omits them."
  def associated(client, repository, sha) do
    with :ok <- Fields.repository(repository),
         :ok <- Fields.sha(sha),
         {:ok, response} <-
           Transport.request(
             client,
             :get,
             "/repos/#{repository}/commits/#{sha}/pulls?per_page=100",
             nil
           ) do
      associated_response(response)
    end
  end

  defp associated_response(%{status: 200, body: pulls})
       when is_list(pulls) and length(pulls) < 100 do
    if Enum.all?(
         pulls,
         &match?(%{"number" => number} when is_integer(number) and number > 0, &1)
       ),
       do: {:ok, Enum.map(pulls, & &1["number"])},
       else: {:error, {:github_protocol_error, :associated_pulls}}
  end

  defp associated_response(%{status: 200}),
    do: {:error, {:github_reconciliation_incomplete, :associated_pulls}}

  defp associated_response(response), do: Transport.error(response)

  defp pull(%{status: 200, body: body}, repository_id, number) do
    with %{
           "number" => ^number,
           "base" => %{"repo" => %{"id" => ^repository_id}, "ref" => base},
           "head" => %{"ref" => branch, "sha" => sha} = head,
           "user" => %{"id" => author_id, "type" => type},
           "state" => state,
           "merged" => merged
         } <- body,
         true <- GitHub.id?(author_id) and type in ["User", "Bot"],
         true <- state in ["open", "closed"] and is_boolean(merged),
         true <- GitObject.id?(sha),
         :ok <- Fields.ref_component(base),
         :ok <- Fields.ref_component(branch) do
      {:ok,
       %{
         "number" => number,
         "repository_id" => repository_id,
         "head_repository_id" => get_in(head, ["repo", "id"]),
         "head" => sha,
         "branch" => branch,
         "base_branch" => base,
         "state" => state,
         "merged" => merged,
         "author_id" => author_id,
         "author_type" => type
       }}
    else
      _invalid -> {:error, {:github_protocol_error, :ci_repair_target}}
    end
  end

  defp pull(response, _repository_id, _number), do: Transport.error(response)

  defp labels(client, repository, number, page, found) do
    with {:ok, response} <-
           Transport.request(
             client,
             :get,
             "/repos/#{repository}/issues/#{number}/labels?per_page=100&page=#{page}",
             nil
           ),
         {:ok, names, count} <- label_page(response) do
      cond do
        count < 100 -> {:ok, found ++ names}
        page >= 10 -> {:error, {:github_reconciliation_incomplete, :ci_repair_labels}}
        true -> labels(client, repository, number, page + 1, found ++ names)
      end
    end
  end

  defp label_page(%{status: 200, body: labels}) when is_list(labels) do
    if Enum.all?(labels, &match?(%{"name" => name} when is_binary(name), &1)),
      do: {:ok, Enum.map(labels, & &1["name"]), length(labels)},
      else: {:error, {:github_protocol_error, :ci_repair_labels}}
  end

  defp label_page(response), do: Transport.error(response)
end
