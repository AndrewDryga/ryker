defmodule Responder.Settings.Edit do
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
