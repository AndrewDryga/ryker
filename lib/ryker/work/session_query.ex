defmodule Ryker.Work.SessionQuery do
  @moduledoc "Work sessions, for every read of `episode_work_sessions`."
  import Ecto.Query
  alias Ryker.Work.Session

  def all, do: from(sessions in Session, as: :episode_work_sessions)

  def by_id(queryable \\ all(), id), do: where(queryable, [episode_work_sessions: s], s.id == ^id)

  def select_generation(queryable),
    do: select(queryable, [episode_work_sessions: s], s.generation)
end
