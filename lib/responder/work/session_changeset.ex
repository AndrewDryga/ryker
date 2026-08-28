defmodule Responder.Work.SessionChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Work.Session

  @spec insert(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), String.t(), String.t(), String.t()) ::
          Ecto.Changeset.t()
  def insert(id, episode_id, generation, policy, policy_digest, external_ref) do
    %Session{}
    |> cast(
      %{
        id: id,
        episode_id: episode_id,
        generation: generation,
        create_generation: 1,
        policy: policy,
        policy_digest: policy_digest,
        external_ref: external_ref
      },
      [
        :id,
        :episode_id,
        :generation,
        :create_generation,
        :policy,
        :policy_digest,
        :external_ref
      ]
    )
    |> validate_required([
      :id,
      :episode_id,
      :generation,
      :create_generation,
      :policy,
      :policy_digest,
      :external_ref
    ])
    |> validate_length(:policy, min: 1, max: 1_024)
    |> validate_format(:policy_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:external_ref, min: 1, max: 1_024)
    |> unique_constraint([:episode_id, :generation])
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:policy, name: :episode_work_session_identity_valid)
  end

  @spec bind(Session.t(), String.t()) :: Ecto.Changeset.t()
  def bind(%Session{} = session, coop_session_id) do
    session
    |> cast(%{coop_session_id: coop_session_id}, [:coop_session_id])
    |> validate_required([:coop_session_id])
    |> validate_length(:coop_session_id, min: 1, max: 1_024)
    |> unique_constraint(:coop_session_id)
  end

  @spec advance_create(Session.t(), pos_integer()) :: Ecto.Changeset.t()
  def advance_create(%Session{} = session, create_generation) do
    session
    |> cast(%{create_generation: create_generation}, [:create_generation])
    |> validate_required([:create_generation])
    |> check_constraint(:create_generation, name: :episode_work_session_identity_valid)
  end
end
