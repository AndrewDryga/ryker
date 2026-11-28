defmodule Ryker.CoopFleet.ModelBucket.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.CoopFleet.ModelBucket

  def all, do: from(buckets in ModelBucket, as: :model_buckets)
  def by_id(queryable \\ all(), id), do: where(queryable, [model_buckets: b], b.id == ^id)
end
