defmodule Responder.Settings.Slack do
  @moduledoc "Slack connection: verified identity, desired enabled state and access lists."
  use Ecto.Schema
  import Ecto.Changeset
  alias Responder.Settings.Validation

  @primary_key {:id, :string, autogenerate: false}
  @fields ~w(enabled workspace_ref bot_ref bot_user_ref default_repository_ref channel_prefix incident_private default_participation operators incident_invite_users)a

  schema "slack_settings" do
    field(:enabled, :boolean, default: false)
    field(:workspace_ref, :string)
    field(:bot_ref, :string)
    field(:bot_user_ref, :string)
    field(:default_repository_ref, :string)
    field(:channel_prefix, :string, default: "ems")
    field(:incident_private, :boolean, default: true)

    field(:default_participation, Ecto.Enum,
      values: [:mentions, :proactive, :shadow],
      default: :mentions
    )

    field(:operators, {:array, :string}, default: [])
    field(:incident_invite_users, {:array, :string}, default: [])
  end

  def fields, do: @fields

  def changeset(current, attributes, snapshot) do
    repositories = Enum.map(snapshot.repositories, & &1.ref)

    current
    |> cast(attributes, @fields)
    |> validate_required([:enabled, :channel_prefix, :incident_private, :default_participation])
    |> validate_format(:workspace_ref, Validation.slack_id_pattern())
    |> validate_format(:bot_ref, Validation.slack_id_pattern())
    |> validate_format(:bot_user_ref, Validation.slack_id_pattern())
    |> validate_format(:channel_prefix, ~r/\A[a-z0-9_-]{1,20}\z/)
    |> Validation.validate_known(:default_repository_ref, repositories, :unknown_repository)
    |> Validation.validate_slack_ids(:operators)
    |> Validation.validate_slack_ids(:incident_invite_users)
    |> validate_length(:operators, max: 256)
    |> validate_length(:incident_invite_users, max: 256)
    |> validate_enabled()
  end

  defp validate_enabled(changeset) do
    if get_field(changeset, :enabled),
      do:
        Enum.reduce(
          [:workspace_ref, :bot_ref, :bot_user_ref, :default_repository_ref],
          changeset,
          &require_to_enable/2
        ),
      else: changeset
  end

  defp require_to_enable(field, changeset) do
    if is_nil(get_field(changeset, field)),
      do:
        add_error(changeset, field, "is required to enable Slack",
          validation: :required_to_enable
        ),
      else: changeset
  end
end
