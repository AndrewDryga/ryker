defmodule Responder.Instructions.Edit do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "model_instruction_edits" do
    field(:scope_ref, :string)
    field(:revision, :integer)
    field(:actor_ref, :string)
    field(:text_fingerprint, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
