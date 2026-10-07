defmodule Ryker.Settings.GitHubBinding.Query do
  @moduledoc "GitHub App installations bound to repositories, for every read of `github_binding_settings`."
  import Ecto.Query
  alias Ryker.Settings.GitHubBinding

  def all, do: from(rows in GitHubBinding, as: :github_binding_settings)

  def ordered_by_name(queryable), do: order_by(queryable, [github_binding_settings: b], b.name)
end
