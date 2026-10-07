defmodule Ryker.CoopFleet.CertificateQuery do
  @moduledoc "Worker client certificates, for every read of `coop_worker_certificates`."
  import Ecto.Query
  alias Ryker.CoopFleet.{Certificate, Worker}

  def all, do: from(certificates in Certificate, as: :coop_worker_certificates)

  def by_sha256(queryable \\ all(), sha256),
    do: where(queryable, [coop_worker_certificates: c], c.sha256 == ^sha256)

  def by_worker_id(queryable \\ all(), worker_id),
    do: where(queryable, [coop_worker_certificates: c], c.worker_id == ^worker_id)

  def unrevoked(queryable),
    do: where(queryable, [coop_worker_certificates: c], is_nil(c.revoked_at))

  def excluding_sha256s(queryable, sha256s),
    do: where(queryable, [coop_worker_certificates: c], c.sha256 not in ^sha256s)

  @doc "Certificates in force by the database clock: not revoked, started and not expired."
  def in_force(queryable) do
    where(
      queryable,
      [coop_worker_certificates: c],
      is_nil(c.revoked_at) and c.not_before <= fragment("clock_timestamp()") and
        c.expires_at > fragment("clock_timestamp()")
    )
  end

  @doc "The worker certificate `sha256` identifies while it is in force and the worker not revoked."
  def active_worker_id(sha256) do
    in_force = sha256 |> by_sha256() |> in_force()

    from(c in in_force,
      join: w in Worker,
      on: w.id == c.worker_id,
      where: w.state != :revoked,
      select: w.id
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
