defmodule Ryker.Settings.Retention.Query do
  @moduledoc "The installation's retention settings, for every read of `retention_settings`."
  use Ryker, :query
  alias Ryker.Settings.Retention

  def all, do: from(retention in Retention, as: :retention_settings)

  def by_id(queryable \\ all(), id), do: where(queryable, [retention_settings: r], r.id == ^id)

  def select_routing_examples_enabled(queryable \\ all()),
    do: select(queryable, [retention_settings: r], r.routing_examples_enabled)

  def select_work_examples_enabled(queryable \\ all()),
    do: select(queryable, [retention_settings: r], r.work_examples_enabled)

  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")
end
