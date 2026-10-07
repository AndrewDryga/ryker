defmodule Ryker.Learning.SourceExposure.Query do
  @moduledoc "The message sources each Work session was shown, for every read of `episode_work_source_exposures`."
  import Ecto.Query
  alias Ryker.Learning.SourceExposure

  def all, do: from(exposures in SourceExposure, as: :episode_work_source_exposures)

  def by_session_id(queryable \\ all(), session_id),
    do: where(queryable, [episode_work_source_exposures: e], e.session_id == ^session_id)

  def by_observation_ids(queryable, observation_ids) do
    where(
      queryable,
      [episode_work_source_exposures: e],
      e.observation_id in ^observation_ids
    )
  end

  def in_observation_order(queryable),
    do: order_by(queryable, [episode_work_source_exposures: e], asc: e.observation_id)

  def select_receipts(queryable),
    do: select(queryable, [episode_work_source_exposures: e], e.receipt)

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
