defmodule Ryker.Publication.GitHubStatus do
  @moduledoc "Read-only routing for publication follow-up; Coop owns every Git and PR write."

  def get_publication_status(%{repositories: repositories}, github_repository, number)
      when is_map(repositories) and is_binary(github_repository) and is_integer(number) and
             number > 0 do
    matches =
      repositories
      |> Map.values()
      |> Enum.filter(&(&1.github_repository == github_repository))
      |> Enum.map(&Map.take(&1, [:api, :client]))
      |> Enum.uniq()

    case matches do
      [%{api: api, client: client}] ->
        api.get_publication_status(client, github_repository, number)

      _none_or_ambiguous ->
        {:error, {:publication_repository_not_configured, github_repository}}
    end
  end

  def get_publication_status(_binding, _repository, _number),
    do: {:error, :publication_repository_not_configured}
end
