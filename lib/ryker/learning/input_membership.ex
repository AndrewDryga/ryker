defmodule Ryker.Learning.InputMembership do
  @moduledoc false
  use Ryker, :schema

  @primary_key false
  schema "conversation_learning_inputs" do
    field(:input_id, :binary_id, primary_key: true)
    field(:batch_id, :binary_id)
    field(:terminal_reason, :string)
    timestamps()
  end
end
