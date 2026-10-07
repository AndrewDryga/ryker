defmodule Ryker.Instructions.SettingQuery do
  @moduledoc "Saved custom instructions, for every read of `model_instruction_settings`."
  import Ecto.Query
  alias Ryker.Instructions.Setting

  def all, do: from(settings in Setting, as: :model_instruction_settings)

  def by_scope_ref(queryable \\ all(), scope_ref),
    do: where(queryable, [model_instruction_settings: s], s.scope_ref == ^scope_ref)

  def by_scope_refs(queryable \\ all(), scope_refs),
    do: where(queryable, [model_instruction_settings: s], s.scope_ref in ^scope_refs)

  def with_text(queryable), do: where(queryable, [model_instruction_settings: s], s.text != "")

  def select_scope_refs(queryable),
    do: select(queryable, [model_instruction_settings: s], s.scope_ref)
end
