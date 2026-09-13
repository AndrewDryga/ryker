defmodule Ryker.Cutover.Run do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "responder_cutover_runs" do
    field(:version, :integer)
    field(:status, Ecto.Enum, values: [:prepared, :applying, :applied, :rolled_back, :failed])
    field(:manifest_sha256, :string)
    field(:review_sha256, :string)
    field(:source_kind, :string)
    field(:source_schema_sha256, :string)
    field(:source_schema_version, :integer)
    field(:source_sha256, :string)
    field(:workspace_ref, :string)
    field(:cutover_at, :utc_datetime_usec)
    field(:reviewed_at, :utc_datetime_usec)
    field(:operator_ref, :string)
    field(:summary, Ryker.CanonicalJSON.Type)
    field(:item_count, :integer)
    field(:applied_at, :utc_datetime_usec)
    field(:rolled_back_at, :utc_datetime_usec)
    field(:rolled_back_by, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
