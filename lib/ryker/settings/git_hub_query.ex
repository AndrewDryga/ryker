defmodule Ryker.Settings.GitHubQuery do
  @moduledoc "The installation's GitHub App, for every read of `github_settings`."
  import Ecto.Query
  alias Ryker.Settings.GitHub

  def all, do: from(rows in GitHub, as: :github_settings)

  def by_id(queryable \\ all(), id), do: where(queryable, [github_settings: g], g.id == ^id)
end
