defmodule Ryker.Settings.WorkQuery do
  @moduledoc "How Work and routing run, for every read of `work_settings`."
  import Ecto.Query
  alias Ryker.Settings.Work

  def all, do: from(settings in Work, as: :work_settings)

  def by_id(queryable \\ all(), id), do: where(queryable, [work_settings: w], w.id == ^id)

  def select_workspace_ref(queryable \\ all()),
    do: select(queryable, [work_settings: w], w.workspace_ref)

  def select_local_routing(queryable \\ all()) do
    select(queryable, [work_settings: w], %{
      mode: w.local_routing_mode,
      endpoint: w.local_routing_endpoint,
      model: w.local_routing_model
    })
  end
end
