defmodule Ryker.Settings.RetentionQuery do
  @moduledoc "The installation's retention settings, for every read of `retention_settings`."
  import Ecto.Query
  alias Ryker.Settings.Retention

  def all, do: from(retention in Retention, as: :retention_settings)

  def select_routing_examples_enabled(queryable \\ all()),
    do: select(queryable, [retention_settings: r], r.routing_examples_enabled)

  def select_work_examples_enabled(queryable \\ all()),
    do: select(queryable, [retention_settings: r], r.work_examples_enabled)

  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
end
