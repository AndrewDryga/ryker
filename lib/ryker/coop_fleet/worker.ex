defmodule Ryker.CoopFleet.Worker do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "coop_workers" do
    field(:workspace_ref, :string)
    field(:certificate_sha256, :string)
    field(:protocol_version, :string)
    field(:build_version, :string)
    field(:clock_at, :utc_datetime_usec)
    field(:sandbox_digest, :string)
    field(:policy_digests, Ryker.CanonicalJSON.Type, default: %{})
    field(:policy_authority_digests, Ryker.CanonicalJSON.Type, default: %{})
    field(:repositories, Ryker.CanonicalJSON.Type, default: [])
    field(:capabilities, Ryker.CanonicalJSON.Type, default: [])
    field(:capacity, Ryker.CanonicalJSON.Type, default: %{})
    # Absent means the worker reported no measurement. Unknown is not zero.
    field(:storage, Ryker.CanonicalJSON.Type)
    field(:storage_reclaimed_bytes, :integer, default: 0)

    field(:state, Ecto.Enum,
      values: [:offline, :eligible, :busy, :draining, :needs_auth, :revoked],
      default: :offline
    )

    field(:last_seen_at, :utc_datetime_usec)
    field(:drain_requested_at, :utc_datetime_usec)
    field(:drain_requested_by, :string)
    field(:revoked_at, :utc_datetime_usec)
    field(:revoked_by, :string)

    timestamps(type: :utc_datetime_usec)
  end
end
