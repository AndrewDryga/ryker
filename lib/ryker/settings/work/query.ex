defmodule Ryker.Settings.Work.Query do
  @moduledoc "How Work and routing run, for every read of `work_settings`."
  use Ryker, :query
  alias Ryker.Settings.Work

  def all, do: from(settings in Work, as: :work_settings)

  def by_id(queryable \\ all(), id), do: where(queryable, [work_settings: w], w.id == ^id)

  def skill_selections(environment_ref) do
    from(w in all(),
      left_join: e in Ryker.Settings.Environment,
      on: e.ref == ^(environment_ref || ""),
      select: {w.installed_skills, w.enabled_skills, e.enabled_skills}
    )
  end

  def select_workspace_ref(queryable \\ all()),
    do: select(queryable, [work_settings: w], w.workspace_ref)
end
