defmodule Ryker.CoopFleet.ModelPermit.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.CoopFleet.ModelPermit

  def all, do: from(permits in ModelPermit, as: :model_permits)
  def by_id(queryable \\ all(), id), do: where(queryable, [model_permits: p], p.id == ^id)
  def bucket(queryable \\ all(), id), do: where(queryable, [model_permits: p], p.bucket_id == ^id)
  def held(queryable \\ all()), do: where(queryable, [model_permits: p], p.state != :released)
  def local(queryable, boot), do: where(queryable, [model_permits: p], p.owner_boot == ^boot)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
