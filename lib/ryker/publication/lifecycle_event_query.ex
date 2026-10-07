defmodule Ryker.Publication.LifecycleEventQuery do
  @moduledoc "What happened to each published change, for every read of `episode_publication_lifecycle_events`."
  import Ecto.Query
  alias Ryker.Publication.LifecycleEvent

  def all, do: from(events in LifecycleEvent, as: :episode_publication_lifecycle_events)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [episode_publication_lifecycle_events: e], e.id == ^id)
end
