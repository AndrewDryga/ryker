defmodule Responder.CoopFleet.Worker do
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
    field(:policy_digests, Responder.CanonicalJSON.Type, default: %{})
    field(:repositories, Responder.CanonicalJSON.Type, default: [])
    field(:capabilities, Responder.CanonicalJSON.Type, default: [])
    field(:capacity, Responder.CanonicalJSON.Type, default: %{})

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
