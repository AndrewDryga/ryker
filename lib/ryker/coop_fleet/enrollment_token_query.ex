defmodule Ryker.CoopFleet.EnrollmentTokenQuery do
  @moduledoc "One-use worker enrollment tokens, for every read of `coop_worker_enrollment_tokens`."
  import Ecto.Query
  alias Ryker.CoopFleet.EnrollmentToken

  def all, do: from(tokens in EnrollmentToken, as: :coop_worker_enrollment_tokens)

  def for_worker(queryable \\ all(), worker_id, workspace_ref) do
    where(
      queryable,
      [coop_worker_enrollment_tokens: t],
      t.worker_id == ^worker_id and t.workspace_ref == ^workspace_ref
    )
  end

  def by_digest(queryable \\ all(), token_sha256),
    do: where(queryable, [coop_worker_enrollment_tokens: t], t.token_sha256 == ^token_sha256)

  def by_operator(queryable \\ all(), operator_ref),
    do: where(queryable, [coop_worker_enrollment_tokens: t], t.operator_ref == ^operator_ref)

  @doc "Not yet used and not yet expired at `now`."
  def usable_at(queryable, now) do
    where(
      queryable,
      [coop_worker_enrollment_tokens: t],
      is_nil(t.consumed_at) and t.expires_at > ^now
    )
  end
end
