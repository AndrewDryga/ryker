defmodule Ryker.CoopFleet.Command do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "coop_worker_commands" do
    belongs_to(:placement, Ryker.CoopFleet.Placement)
    field(:worker_id, :string)
    field(:session_id, :binary_id)
    field(:placement_generation, :integer)
    field(:kind, :string)
    field(:command_version, :integer, default: 2)
    field(:payload, Ryker.CanonicalJSON.Type)
    field(:payload_fingerprint, :string)
    field(:idempotency_key, :string)

    field(:status, Ecto.Enum,
      values: [:queued, :delivered, :acknowledged, :succeeded, :failed, :uncertain],
      default: :queued
    )

    field(:operation_key, :string)
    field(:result, Ryker.CanonicalJSON.Type)
    field(:error, Ryker.CanonicalJSON.Type)
    field(:result_fingerprint, :string)
    field(:delivered_at, :utc_datetime_usec)
    field(:acknowledged_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  # A read answers only the caller that asked: its key is fresh, and nothing
  # asks for the same answer again (`Ryker.CoopFleet.Client`).
  @read_key_prefix "ryker:fleet:read:"

  @doc "A fresh key for a read named `name`, whose answer only its caller waits for."
  @spec read_key(String.t()) :: String.t()
  def read_key(name), do: "#{@read_key_prefix}#{name}:#{Ecto.UUID.generate()}"

  @doc "What the key of every read starts with."
  @spec read_key_prefix() :: String.t()
  def read_key_prefix, do: @read_key_prefix
end
