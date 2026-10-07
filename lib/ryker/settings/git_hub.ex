defmodule Ryker.Settings.GitHub do
  @moduledoc "GitHub App connection: verified app identity and desired enabled state."
  use Ryker, :schema

  @primary_key {:id, :string, autogenerate: false}

  schema "github_settings" do
    field(:enabled, :boolean, default: false)
    field(:app_id, :integer)
    field(:app_slug, :string)
    field(:api_url, :string, default: "https://api.github.com")
    field(:auto_add_repositories, :boolean, default: false)
    field(:bot_actor_id, :integer)
    field(:bot_login, :string)
  end

  @type t :: %__MODULE__{}
end
