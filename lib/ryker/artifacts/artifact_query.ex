defmodule Ryker.Artifacts.ArtifactQuery do
  @moduledoc "Input artifacts, for every read in `Ryker.Artifacts`."
  import Ecto.Query
  alias Ryker.Artifacts.Artifact

  def all, do: from(artifacts in Artifact, as: :input_artifacts)

  def by_source(queryable \\ all(), source_kind, source_ref) do
    where(
      queryable,
      [input_artifacts: a],
      a.source_kind == ^source_kind and a.source_ref == ^source_ref
    )
  end

  def by_refs(queryable \\ all(), refs),
    do: where(queryable, [input_artifacts: a], a.ref in ^refs)

  def ordered_by_ref(queryable), do: order_by(queryable, [input_artifacts: a], a.ref)

  # The artifacts stay while the references that name them are written.
  def lock_for_key_share(queryable), do: lock(queryable, "FOR KEY SHARE")
end
