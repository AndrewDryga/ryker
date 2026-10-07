defmodule Ryker.Settings.InstallationQuery do
  @moduledoc "The installation's identity and settings revision, for every read of `installation_settings`."
  import Ecto.Query
  alias Ryker.Settings.Installation

  def all, do: from(rows in Installation, as: :installation_settings)

  def select_revision(queryable \\ all()),
    do: select(queryable, [installation_settings: i], i.revision)

  @doc "The installation while its newest saved settings are still being applied."
  def applying(queryable \\ all()) do
    where(
      queryable,
      [installation_settings: i],
      i.applied_revision < i.revision and is_nil(i.failure_code)
    )
  end

  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
end
