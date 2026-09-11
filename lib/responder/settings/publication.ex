defmodule Responder.Settings.Publication do
  @moduledoc "Draft publication identity; credentials alone never enable publishing."
  use Ecto.Schema
  import Ecto.Changeset
  alias Responder.Settings.Validation

  @primary_key {:id, :string, autogenerate: false}
  @fields ~w(enabled branch_prefix commit_name commit_email)a

  schema "publication_settings" do
    field(:enabled, :boolean, default: false)
    field(:branch_prefix, :string, default: "responder")
    field(:commit_name, :string, default: "Responder")
    field(:commit_email, :string, default: "responder@localhost")
  end

  def fields, do: @fields

  def changeset(current, attributes, snapshot) do
    changeset =
      current
      |> cast(attributes, @fields)
      |> validate_required(@fields)
      |> Validation.validate_git_ref(:branch_prefix)
      |> validate_length(:commit_name, min: 1, max: 256)
      |> validate_length(:commit_email, max: 320)
      |> validate_format(:commit_email, Validation.email_pattern())

    if get_field(changeset, :enabled) and not snapshot.github.enabled,
      do: add_error(changeset, :enabled, "requires GitHub", validation: :github_required),
      else: changeset
  end
end
