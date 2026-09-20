defmodule Ryker.Settings.GitHub do
  @moduledoc "GitHub App connection: verified app identity and desired enabled state."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @fields ~w(enabled app_id app_slug api_url auto_add_repositories bot_actor_id bot_login)a

  schema "github_settings" do
    field(:enabled, :boolean, default: false)
    field(:app_id, :integer)
    field(:app_slug, :string)
    field(:api_url, :string, default: "https://api.github.com")
    field(:auto_add_repositories, :boolean, default: false)
    field(:bot_actor_id, :integer)
    field(:bot_login, :string)
  end

  def fields, do: @fields

  def changeset(current, attributes, _snapshot) do
    changeset =
      current
      |> cast(attributes, @fields)
      |> validate_required([:enabled])
      |> validate_number(:app_id, greater_than: 0)
      |> validate_length(:app_slug, min: 1, max: 256)
      |> validate_number(:bot_actor_id, greater_than: 0)
      |> validate_length(:bot_login, min: 1, max: 256)
      |> validate_url(:api_url)

    changeset =
      changeset
      |> validate_identity_pair(:bot_actor_id, :bot_login)

    if get_field(changeset, :enabled) and is_nil(get_field(changeset, :app_id)),
      do:
        add_error(changeset, :app_id, "is required to enable GitHub",
          validation: :required_to_enable
        ),
      else: changeset
  end

  defp validate_identity_pair(changeset, id_field, login_field) do
    id = get_field(changeset, id_field)
    login = get_field(changeset, login_field)

    if (is_nil(id) and is_binary(login)) or (is_integer(id) and is_nil(login)),
      do:
        add_error(changeset, login_field, "must be verified with its GitHub identity",
          validation: :identity_pair
        ),
      else: changeset
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      case URI.parse(value) do
        %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil}
        when is_binary(host) and host != "" and byte_size(value) <= 2_048 ->
          []

        _invalid ->
          [
            {field,
             {"must be an HTTPS URL without credentials, query or fragment",
              [validation: :format]}}
          ]
      end
    end)
  end
end
