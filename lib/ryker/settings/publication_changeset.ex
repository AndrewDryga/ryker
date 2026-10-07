defmodule Ryker.Settings.PublicationChangeset do
  @moduledoc "Changes to draft publication (`Ryker.Settings.Publication`)."
  @behaviour Ryker.Settings.SectionChangeset

  import Ecto.Changeset
  alias Ryker.Settings.{Publication, Validation}

  @fields ~w(enabled branch_prefix)a

  @impl true
  def fields, do: @fields

  # A prefix is the folder branches go in, written with or without its slash:
  # "ryker/" and "ryker" both name ryker/<task>. Pull requests need the GitHub
  # App verified, not a repository added yet (Andrew, 2026-10-03, on a
  # verified App: "errors don't make sense").
  @impl true
  def update(%Publication{} = publication, attributes, snapshot) do
    changeset =
      publication
      |> cast(attributes, @fields)
      |> update_change(:branch_prefix, &String.trim_trailing(&1, "/"))
      |> validate_required(@fields)
      |> Validation.validate_git_ref(:branch_prefix)

    if get_field(changeset, :enabled) and is_nil(snapshot.github.app_id),
      do: add_error(changeset, :enabled, "requires GitHub", validation: :github_required),
      else: changeset
  end
end
