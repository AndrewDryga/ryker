defmodule Ryker.Settings.Publication do
  @moduledoc "Draft publication settings; credentials alone never enable publishing."
  use Ecto.Schema
  import Ecto.Changeset
  alias Ryker.Settings.Validation

  @primary_key {:id, :string, autogenerate: false}
  @fields ~w(enabled branch_prefix)a

  schema "publication_settings" do
    field(:enabled, :boolean, default: false)
    field(:branch_prefix, :string, default: "ryker")
  end

  def fields, do: @fields

  def changeset(current, attributes, snapshot) do
    changeset =
      current
      |> cast(attributes, @fields)
      |> validate_required(@fields)
      |> Validation.validate_git_ref(:branch_prefix)

    if get_field(changeset, :enabled) and not snapshot.github.enabled,
      do: add_error(changeset, :enabled, "requires GitHub", validation: :github_required),
      else: changeset
  end
end
