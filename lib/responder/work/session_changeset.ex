defmodule Responder.Work.SessionChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Work.Session

  @spec insert(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          pos_integer(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t(),
          map() | nil
        ) ::
          Ecto.Changeset.t()
  def insert(
        id,
        episode_id,
        generation,
        policy,
        policy_digest,
        repository_ref,
        external_ref,
        workspace_task \\ nil
      ) do
    insert_with_authority(
      id,
      episode_id,
      generation,
      policy,
      policy_digest,
      repository_ref,
      external_ref,
      %{authority_digest: nil, workspace_task: workspace_task}
    )
  end

  @spec insert_with_authority(
          Ecto.UUID.t(),
          Ecto.UUID.t(),
          pos_integer(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t(),
          %{authority_digest: String.t() | nil, workspace_task: map() | nil}
        ) ::
          Ecto.Changeset.t()
  def insert_with_authority(
        id,
        episode_id,
        generation,
        policy,
        policy_digest,
        repository_ref,
        external_ref,
        %{authority_digest: authority_digest, workspace_task: workspace_task}
      ) do
    %Session{}
    |> cast(
      %{
        id: id,
        episode_id: episode_id,
        generation: generation,
        create_generation: 1,
        policy: policy,
        policy_digest: policy_digest,
        authority_digest: authority_digest,
        repository_ref: repository_ref,
        external_ref: external_ref,
        workspace_task: workspace_task
      },
      [
        :id,
        :episode_id,
        :generation,
        :create_generation,
        :policy,
        :policy_digest,
        :authority_digest,
        :repository_ref,
        :external_ref,
        :workspace_task
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
    |> validate_format(:authority_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:repository_ref, min: 1, max: 1_024)
    |> validate_length(:external_ref, min: 1, max: 1_024)
    |> validate_workspace_task()
    |> unique_constraint([:episode_id, :generation])
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:policy, name: :episode_work_session_identity_valid)
    |> check_constraint(:repository_ref, name: :episode_work_session_repository_valid)
  end

  @spec bind(Session.t(), String.t()) :: Ecto.Changeset.t()
  def bind(%Session{} = session, coop_session_id) do
    session
    |> cast(%{coop_session_id: coop_session_id}, [:coop_session_id])
    |> validate_required([:coop_session_id])
    |> validate_length(:coop_session_id, min: 1, max: 1_024)
    |> unique_constraint(:coop_session_id)
  end

  @spec bind_workspace_task(Session.t(), map()) :: Ecto.Changeset.t()
  def bind_workspace_task(%Session{} = session, workspace_task) do
    session
    |> cast(%{workspace_task: workspace_task}, [:workspace_task])
    |> validate_required([:workspace_task])
    |> validate_workspace_task()
    |> check_constraint(:workspace_task, name: :episode_work_session_workspace_task_valid)
  end

  @spec advance_create(Session.t(), pos_integer()) :: Ecto.Changeset.t()
  def advance_create(%Session{} = session, create_generation) do
    session
    |> cast(%{create_generation: create_generation}, [:create_generation])
    |> validate_required([:create_generation])
    |> check_constraint(:create_generation, name: :episode_work_session_identity_valid)
  end

  defp validate_workspace_task(changeset) do
    validate_change(changeset, :workspace_task, fn :workspace_task, value ->
      case Responder.CanonicalJSON.validate(value, max_bytes: 64 * 1_024) do
        :ok -> []
        {:error, _reason} -> [workspace_task: "is outside its canonical byte bound"]
      end
    end)
  end
end
