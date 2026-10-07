defmodule Ryker.CoopFleet.EnrollmentTokenChangeset do
  @moduledoc "How a worker enrollment token is minted and used (`Ryker.CoopFleet.EnrollmentToken`)."
  import Ecto.Changeset
  alias Ryker.CoopFleet.EnrollmentToken

  @fields [:expires_at, :operator_ref, :token_sha256, :worker_id, :workspace_ref]

  @doc "A token an operator minted for one worker in one workspace, kept as its digest."
  def insert(attributes) do
    %EnrollmentToken{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:token_sha256)
    |> check_constraint(:worker_id, name: :coop_worker_enrollment_token_valid)
  end

  @doc "The token is spent on the certificate it bound."
  def consume(%EnrollmentToken{} = token, certificate_sha256, at) do
    token
    |> change(certificate_sha256: certificate_sha256, consumed_at: at)
    |> check_constraint(:certificate_sha256, name: :coop_worker_enrollment_token_valid)
  end
end
