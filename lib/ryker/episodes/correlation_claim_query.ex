defmodule Ryker.Episodes.CorrelationClaimQuery do
  @moduledoc "Which request owns each recurring occurrence, for every read of `episode_correlation_claims`."
  import Ecto.Query
  alias Ryker.Episodes.CorrelationClaim

  def all, do: from(claims in CorrelationClaim, as: :episode_correlation_claims)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_correlation_claims: c], c.episode_id == ^episode_id)

  def by_episode_ids(queryable \\ all(), episode_ids),
    do: where(queryable, [episode_correlation_claims: c], c.episode_id in ^episode_ids)

  @doc "The occurrence `occurrence_ref` of `namespace` in `scope_ref`."
  def by_occurrence(scope_ref, namespace, occurrence_ref) do
    where(
      all(),
      [episode_correlation_claims: c],
      c.scope_ref == ^scope_ref and c.namespace == ^namespace and
        c.occurrence_ref == ^occurrence_ref
    )
  end

  def active(queryable),
    do: where(queryable, [episode_correlation_claims: c], c.status == :active)

  def lifecycle_active(queryable),
    do: where(queryable, [episode_correlation_claims: c], c.lifecycle_state == :active)

  def newest_first(queryable) do
    order_by(queryable, [episode_correlation_claims: c], desc: c.inserted_at, desc: c.id)
  end

  def select_occurrence_refs(queryable),
    do: select(queryable, [episode_correlation_claims: c], c.occurrence_ref)

  def limit_to(queryable, count), do: limit(queryable, ^count)

  def in_established_order(queryable) do
    order_by(queryable, [episode_correlation_claims: c],
      asc: c.established_at,
      asc: c.occurrence_ref
    )
  end
end
