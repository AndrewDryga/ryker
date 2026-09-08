defmodule Responder.Learning.InputMembership do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "conversation_learning_inputs" do
    field(:input_id, :binary_id, primary_key: true)
    field(:batch_id, :binary_id)
    field(:terminal_reason, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
