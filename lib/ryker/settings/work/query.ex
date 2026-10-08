defmodule Ryker.Settings.Work.Query do
  @moduledoc "How Work and routing run, for every read of `work_settings`."
  use Ryker, :query
  alias Ryker.Settings.Work

  def all, do: from(settings in Work, as: :work_settings)

  def by_id(queryable \\ all(), id), do: where(queryable, [work_settings: w], w.id == ^id)

  def select_workspace_ref(queryable \\ all()),
    do: select(queryable, [work_settings: w], w.workspace_ref)
end
