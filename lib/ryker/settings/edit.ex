defmodule Ryker.Settings.Edit do
  @moduledoc false
  use Ecto.Schema

  # Retired policy settings and one-time imports remain readable in audit history.
  # Nothing writes new :policies or :import edits.
  @domains [
    :installation,
    :retention,
    :slack,
    :github,
    :publication,
    :emisar,
    :report,
    :learning,
    :repositories,
    :environments,
    :policies,
    :webhooks,
    :pricing,
    :work,
    :import
  ]
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "settings_edits" do
    field(:domain, Ecto.Enum, values: @domains)
    field(:revision, :integer)
    field(:actor_ref, :string)
    field(:fingerprint, :string)
    field(:inserted_at, :utc_datetime_usec)
  end

  def domains, do: @domains
end
