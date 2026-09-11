defmodule Responder.Settings.GitHub do
  @moduledoc "GitHub App connection: verified app identity and desired enabled state."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @fields ~w(enabled app_id app_slug)a

  schema "github_settings" do
    field(:enabled, :boolean, default: false)
    field(:app_id, :integer)
    field(:app_slug, :string)
  end

  def fields, do: @fields

  def changeset(current, attributes, _snapshot) do
    changeset =
      current
      |> cast(attributes, @fields)
      |> validate_required([:enabled])
      |> validate_number(:app_id, greater_than: 0)
      |> validate_length(:app_slug, min: 1, max: 256)

    if get_field(changeset, :enabled) and is_nil(get_field(changeset, :app_id)),
      do:
        add_error(changeset, :app_id, "is required to enable GitHub",
          validation: :required_to_enable
        ),
      else: changeset
  end
end
