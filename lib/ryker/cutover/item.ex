defmodule Ryker.Cutover.Item do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "responder_cutover_items" do
    belongs_to(:run, Ryker.Cutover.Run)
    field(:ref, :string)
    field(:kind, Ecto.Enum, values: [:memory, :behavior, :schedule, :episode, :wait])
    field(:source_table, :string)
    field(:source_ref, :string)
    field(:source_sha256, :string)
    field(:decision, Ecto.Enum, values: [:import, :skip])
    field(:status, Ecto.Enum, values: [:pending, :applied, :skipped, :rolled_back, :failed])
    field(:data, Ryker.CanonicalJSON.Type)
    field(:target_refs, Ryker.CanonicalJSON.Type)
    field(:target_fingerprint, :string)
    field(:error_code, :string)
    field(:error_detail, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
