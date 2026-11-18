defmodule Ryker.GitHub.CIRepairPolicy do
  @moduledoc "The common repository policy and PR opt-out for every automatic CI repair."

  def eligibility(%{github_ci_repair: :off}, _binding, _pull), do: {:error, :disabled}

  def eligibility(%{github_access: access}, _binding, _pull) when access != :available,
    do: {:error, :repository_unavailable}

  def eligibility(repository, binding, pull) do
    cond do
      "ryker:no-ci-fix" in pull["labels"] ->
        {:error, :skipped}

      pull["state"] != "open" or pull["merged"] ->
        {:error, :closed}

      pull["repository_id"] != binding.repository_id or
          pull["head_repository_id"] != binding.repository_id ->
        {:error, :fork}

      pull["branch"] == pull["base_branch"] ->
        {:error, :default_branch}

      true ->
        ownership(repository.github_ci_repair, binding, pull)
    end
  end

  defp ownership(:all, _binding, _pull), do: :ok

  defp ownership(:own, binding, pull) do
    if pull["author_id"] == binding.ryker_actor_id and pull["author_type"] == "Bot",
      do: :ok,
      else: {:error, :not_owned}
  end
end
