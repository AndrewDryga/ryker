defmodule Ryker.Settings.EnvironmentRepository.Query do
  @moduledoc "The repositories of each environment, for every read of `environment_repository_settings`."
  use Ryker, :query
  alias Ryker.Settings.EnvironmentRepository

  def all, do: from(rows in EnvironmentRepository, as: :environment_repository_settings)

  def by_environment(queryable \\ all(), environment_ref) do
    where(
      queryable,
      [environment_repository_settings: r],
      r.environment_ref == ^environment_ref
    )
  end
end
