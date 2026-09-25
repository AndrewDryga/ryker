defmodule Ryker.Settings.Edit do
  @moduledoc false
  use Ecto.Schema

  # `:import` is the domain the retired one-time configuration importer wrote
  # its installation receipt under on 2026-09-11; nothing records it anymore,
  # but the live edit history still holds that row.
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
