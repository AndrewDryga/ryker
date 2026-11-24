defmodule Ryker.Settings.GitHub.Changeset do
  @moduledoc "Changes to the GitHub App connection (`Ryker.Settings.GitHub`)."
  @behaviour Ryker.Settings.Section.Changeset
  use Ryker, :changeset
  alias Ryker.Settings.GitHub

  @fields ~w(enabled app_id app_slug oauth_client_id api_url auto_add_repositories trusted_installation_ids bot_actor_id bot_login)a

  @impl true
  def fields, do: @fields

  @impl true
  def update(%GitHub{} = github, attributes, _snapshot) do
    changeset =
      github
      |> cast(attributes, @fields)
      |> validate_required([:enabled])
      |> validate_number(:app_id, greater_than: 0)
      |> validate_length(:app_slug, min: 1, max: 256, count: :codepoints)
      |> validate_length(:oauth_client_id, min: 1, max: 256, count: :codepoints)
      |> validate_number(:bot_actor_id, greater_than: 0)
      |> validate_length(:bot_login, min: 1, max: 256, count: :codepoints)
      |> validate_url(:api_url)
      |> installation_trust()
      |> validate_identity_pair(:bot_actor_id, :bot_login)

    if get_field(changeset, :enabled) and is_nil(get_field(changeset, :app_id)) do
      add_error(changeset, :app_id, "is required to enable GitHub",
        validation: :required_to_enable
      )
    else
      changeset
    end
  end

  defp installation_trust(changeset) do
    if changed?(changeset, :app_id) or changed?(changeset, :api_url) do
      put_change(changeset, :trusted_installation_ids, [])
    else
      validate_change(changeset, :trusted_installation_ids, &validate_installations/2)
    end
  end

  defp validate_installations(field, ids) do
    if Enum.all?(ids, &(is_integer(&1) and &1 > 0 and &1 <= 9_223_372_036_854_775_807)) and
         Enum.uniq(ids) == ids,
       do: [],
       else: [{field, "must contain distinct positive installation IDs"}]
  end

  defp validate_identity_pair(changeset, id_field, login_field) do
    id = get_field(changeset, id_field)
    login = get_field(changeset, login_field)

    if (is_nil(id) and is_binary(login)) or (is_integer(id) and is_nil(login)) do
      add_error(changeset, login_field, "must be verified with its GitHub identity",
        validation: :identity_pair
      )
    else
      changeset
    end
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
