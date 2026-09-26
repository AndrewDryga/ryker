defmodule Ryker.StateTools.CallRecord do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "episode_work_state_tool_calls" do
    belongs_to(:turn, Ryker.Work.Turn)
    field(:tool, :string)
    field(:status, :string)
    field(:arguments, Ryker.CanonicalJSON.Type)
    field(:error, Ryker.CanonicalJSON.Type)
    field(:called_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          turn_id: Ecto.UUID.t() | nil,
          tool: String.t() | nil,
          status: String.t() | nil,
          arguments: term(),
          error: term(),
          called_at: DateTime.t() | nil
        }
end
