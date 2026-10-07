defmodule Ryker.Settings.Slack do
  @moduledoc "Slack connection: verified identity, desired enabled state and access lists."
  use Ryker, :schema

  @primary_key {:id, :string, autogenerate: false}

  schema "slack_settings" do
    field(:enabled, :boolean, default: false)
    field(:workspace_ref, :string)
    field(:workspace_url, :string)
    field(:workspace_name, :string)
    field(:bot_ref, :string)
    field(:bot_user_ref, :string)
    field(:bot_name, :string)
    field(:channel_prefix, :string, default: "inc")
    field(:incident_private, :boolean, default: true)

    field(:default_participation, Ecto.Enum,
      values: [:mentions, :proactive, :shadow],
      default: :mentions
    )

    field(:operators, {:array, :string}, default: [])
    # Whether the workspace's admins and owners can manage Ryker beside the
    # people in `operators`. Slack says who they are when it matters.
    field(:workspace_admins_manage, :boolean, default: true)
  end

  @type t :: %__MODULE__{}
end
