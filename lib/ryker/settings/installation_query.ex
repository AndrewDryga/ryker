defmodule Ryker.Settings.InstallationQuery do
  @moduledoc "The installation's identity and settings revision, for every read of `installation_settings`."
  import Ecto.Query
  alias Ryker.Settings.Installation

  def all, do: from(rows in Installation, as: :installation_settings)

  def select_revision(queryable \\ all()),
    do: select(queryable, [installation_settings: i], i.revision)
end
