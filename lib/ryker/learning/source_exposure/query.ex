defmodule Ryker.Learning.SourceExposure.Query do
  @moduledoc "The message sources each Work session was shown, for every read of `episode_work_source_exposures`."
  use Ryker, :query
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

  @doc "Existing receiver roots whose producer custody requires the automatic role."
  def with_joined_automatic_sources(queryable, session_ids) do
    from([episode_work_source_exposures: e] in queryable,
      join: p in SourceExposure,
      as: :automatic_source_exposures,
      on: p.observation_id == e.observation_id and p.source_input_id == e.source_input_id,
      where: p.session_id in ^session_ids and p.automatic_context,
      where: not e.automatic_context or e.input_only
    )
  end

  def ordered_by_observation(queryable),
    do: order_by(queryable, [episode_work_source_exposures: e], asc: e.observation_id)

  def select_receipts(queryable),
    do: select(queryable, [episode_work_source_exposures: e], e.receipt)

  def limit_to(queryable, count), do: limit(queryable, ^count)
end
