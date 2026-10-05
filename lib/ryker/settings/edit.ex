defmodule Ryker.Settings.Edit do
  @moduledoc false
  use Ecto.Schema

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
    :webhooks,
    :pricing,
    :work
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
