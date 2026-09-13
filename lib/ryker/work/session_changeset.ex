defmodule Ryker.Work.SessionChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.Work.{RepositoryContext, RepositorySource, Session}

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
          map()
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
        options
      ) do
    authority_digest = Map.fetch!(options, :authority_digest)
    workspace_task = Map.fetch!(options, :workspace_task)
    repository_context = Map.get(options, :repository_context)
    repository_source = Map.get(options, :repository_source)

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
        repository_context: repository_context,
        repository_source: repository_source,
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
        :repository_context,
        :repository_source,
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
    |> validate_repository_context()
    |> validate_repository_source()
    |> validate_workspace_task()
    |> unique_constraint([:episode_id, :generation])
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:policy, name: :episode_work_session_identity_valid)
    |> check_constraint(:repository_ref, name: :episode_work_session_repository_valid)
    |> check_constraint(:repository_context, name: :episode_work_session_repository_context_valid)
    |> check_constraint(:repository_source, name: :episode_work_session_repository_source_valid)
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
      case Ryker.CanonicalJSON.validate(value, max_bytes: 64 * 1_024) do
        :ok -> []
        {:error, _reason} -> [workspace_task: "is outside its canonical byte bound"]
      end
    end)
  end

  defp validate_repository_source(changeset) do
    validate_change(changeset, :repository_source, fn :repository_source, value ->
      valid? =
        not is_nil(get_field(changeset, :repository_ref)) and
          match?({:ok, ^value}, RepositorySource.parse(value))

      if valid?, do: [], else: [repository_source: "is not an authorized repository source"]
    end)
  end

  defp validate_repository_context(changeset) do
    validate_change(changeset, :repository_context, fn :repository_context, value ->
      case RepositoryContext.restore(value, get_field(changeset, :repository_ref)) do
        {:ok, _context} -> []
        {:error, :invalid} -> [repository_context: "is not a bounded repository set"]
      end
    end)
  end
end
