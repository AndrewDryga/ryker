defmodule Ryker.CoopFleet.Certificate.Changeset do
  @moduledoc "How a worker certificate is recorded (`Ryker.CoopFleet.Certificate`)."
  import Ecto.Changeset
  alias Ryker.CoopFleet.Certificate

  @fields [
    :enrollment_token_id,
    :expires_at,
    :issued_by,
    :not_before,
    :serial_number,
    :sha256,
    :source,
    :worker_id
  ]
  # A renewal comes from the certificate it renews, not an enrollment token.
  @required @fields -- [:enrollment_token_id]

  @doc "A certificate issued at enrollment or renewal."
  def insert(attributes) do
    %Certificate{}
    |> cast(attributes, @fields)
    |> validate_required(@required)
    |> foreign_key_constraint(:worker_id)
    |> foreign_key_constraint(:enrollment_token_id)
    |> check_constraint(:sha256, name: :coop_worker_certificate_valid)
  end
end
