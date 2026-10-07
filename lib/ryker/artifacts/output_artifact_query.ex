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
end
