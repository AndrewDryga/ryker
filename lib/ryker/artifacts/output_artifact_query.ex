defmodule Ryker.Artifacts.OutputArtifactQuery do
  @moduledoc "The files a Work turn produced, for every read in `Ryker.Artifacts.Outputs`."
  import Ecto.Query
  alias Ryker.Artifacts.OutputArtifact

  def all, do: from(artifacts in OutputArtifact, as: :work_output_artifacts)

  def by_turn_id(queryable \\ all(), turn_id),
    do: where(queryable, [work_output_artifacts: a], a.turn_id == ^turn_id)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [work_output_artifacts: a], a.ref == ^ref)

  def by_refs(queryable \\ all(), refs),
    do: where(queryable, [work_output_artifacts: a], a.ref in ^refs)

  def by_turn_ids(queryable \\ all(), turn_ids),
    do: where(queryable, [work_output_artifacts: a], a.turn_id in ^turn_ids)

  def ordered_by_name(queryable),
    do: order_by(queryable, [work_output_artifacts: a], asc: a.name, asc: a.ref)

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc "What lists a file without its bytes: its turn, ref, name, type and size."
  def select_listing(queryable) do
    select(
      queryable,
      [work_output_artifacts: a],
      struct(a, [:turn_id, :ref, :name, :media_type, :byte_size])
    )
  end
end
