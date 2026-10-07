defmodule Ryker.Settings.Slack.Changeset do
  @moduledoc "Changes to the Slack connection (`Ryker.Settings.Slack`)."
  @behaviour Ryker.Settings.Section.Changeset

  import Ecto.Changeset
  alias Ryker.Settings.{Slack, Validation}

  @fields ~w(enabled workspace_ref workspace_url workspace_name bot_ref bot_user_ref bot_name channel_prefix incident_private default_participation operators workspace_admins_manage)a

  @impl true
  def fields, do: @fields

  @impl true
  def update(%Slack{} = slack, attributes, _snapshot) do
    slack
    |> cast(attributes, @fields)
    |> validate_required([
      :enabled,
      :channel_prefix,
      :incident_private,
      :default_participation,
      :workspace_admins_manage
    ])
    |> validate_format(:workspace_ref, Validation.slack_id_pattern())
    # The workspace origin is the only part of a Slack message link the host
    # cannot derive. It is an origin, never a path, so a card can build a link
    # from it without ever trusting a stored URL shape.
    |> validate_format(:workspace_url, ~r/\Ahttps:\/\/[a-z0-9-]{1,64}\.slack\.com\/?\z/)
    |> validate_length(:workspace_url, max: 256)
    |> validate_length(:workspace_name, min: 1, max: 256)
    |> validate_format(:bot_ref, Validation.slack_id_pattern())
    |> validate_format(:bot_user_ref, Validation.slack_id_pattern())
    |> validate_length(:bot_name, min: 1, max: 256)
    |> validate_format(:channel_prefix, ~r/\A[a-z0-9_-]{1,20}\z/)
    |> Validation.validate_slack_ids(:operators)
    |> validate_length(:operators, max: 256)
    |> validate_enabled()
  end

  defp validate_enabled(changeset) do
    if get_field(changeset, :enabled) do
      Enum.reduce(
        [:workspace_ref, :bot_ref, :bot_user_ref],
        changeset,
        &require_to_enable/2
      )
    else
      changeset
    end
  end

  defp require_to_enable(field, changeset) do
    if is_nil(get_field(changeset, field)) do
      add_error(changeset, field, "is required to enable Slack", validation: :required_to_enable)
    else
      changeset
    end
  end
end
