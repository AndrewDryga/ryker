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

  # A prefix is the folder branches go in, written with or without its slash:
  # "ryker/" and "ryker" both name ryker/<task>. Pull requests need the GitHub
  # App verified, not a repository added yet (Andrew, 2026-10-03, on a
  # verified App: "errors don't make sense").
  def changeset(current, attributes, snapshot) do
    changeset =
      current
      |> cast(attributes, @fields)
      |> update_change(:branch_prefix, &String.trim_trailing(&1, "/"))
      |> validate_required(@fields)
      |> Validation.validate_git_ref(:branch_prefix)

    if get_field(changeset, :enabled) and is_nil(snapshot.github.app_id),
      do: add_error(changeset, :enabled, "requires GitHub", validation: :github_required),
      else: changeset
  end
end
