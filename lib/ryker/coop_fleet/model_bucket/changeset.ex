defmodule Ryker.CoopFleet.ModelBucket.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.CoopFleet.ModelBucket

  def insert(id),
    do: change(%ModelBucket{}, id: id, concurrency: 1, updated_by: "system:model-access")

  def limit(bucket, count, actor), do: change(bucket, concurrency: count, updated_by: actor)
  def cooldown(bucket, until), do: change(bucket, blocked_until: until)
end
