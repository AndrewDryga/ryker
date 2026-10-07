defmodule Ryker.Settings.Edit do
  @moduledoc false
  use Ryker, :schema

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

  schema "settings_edits" do
    field(:domain, Ecto.Enum, values: @domains)
    field(:revision, :integer)
    field(:actor_ref, :string)
    field(:fingerprint, :string)
    field(:inserted_at, :utc_datetime_usec)
  end

  def domains, do: @domains
end
