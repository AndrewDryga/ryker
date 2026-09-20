defmodule Ryker.Repo.Migrations.MoveConnectionEndpointsIntoSettings do
  use Ecto.Migration

  def change do
    alter table(:github_settings) do
      add(:api_url, :text, null: false, default: "https://api.github.com")
    end

    alter table(:emisar_settings) do
      add(:rpc_url, :text, null: false, default: "https://emisar.dev/api/mcp/rpc")
    end

    create(
      constraint(:github_settings, :github_settings_api_url_valid,
        check:
          "api_url ~ '^https://[^/?#]+(:[0-9]+)?(/[^?#]*)?$' AND char_length(api_url) <= 2048"
      )
    )

    create(
      constraint(:emisar_settings, :emisar_settings_rpc_url_valid,
        check: "rpc_url ~ '^https://[^/?#]+(:[0-9]+)?/[^?#]+$' AND char_length(rpc_url) <= 2048"
      )
    )
  end
end
