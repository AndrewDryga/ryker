defmodule Responder.Instructions.Setting do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:scope_ref, :string, autogenerate: false}

  schema "model_instruction_settings" do
    field(:text, :string, default: "")
    field(:revision, :integer, default: 0)
    field(:saved_by, :string)
    field(:saved_at, :utc_datetime_usec)
  end
end
