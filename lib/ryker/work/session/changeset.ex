defmodule Ryker.Work.Session.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.CoopFleet.JobSpec
  alias Ryker.Work.{RepositoryContext, RepositorySource, Session}

  @admission_fields [
    :cleanup_status,
    :create_generation,
    :execution_kind,
    :admission_input_id,
    :external_ref,
    :generation,
    :id,
    :policy,
    :policy_digest
  ]

  @spec advance_activity_cursor(Session.t(), non_neg_integer()) :: Ecto.Changeset.t()
  def advance_activity_cursor(%Session{} = session, cursor),
    do: change(session, activity_cursor: cursor)

  @spec insert(
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
  def insert(
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
    environment_ref = Map.get(options, :environment_ref)
    worker_job_document = Map.get(options, :worker_job_document)
    worker_job_digest = Map.get(options, :worker_job_digest)
    emisar = Map.get(options, :emisar)

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
        worker_job_document: worker_job_document,
        worker_job_digest: worker_job_digest,
        repository_ref: repository_ref,
        repository_context: repository_context,
        repository_source: repository_source,
        environment_ref: environment_ref,
        emisar_connection_ref: emisar && emisar.connection_ref,
        emisar_account_ref: emisar && emisar.account_ref,
        emisar_rpc_url: emisar && emisar.rpc_url,
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
        :worker_job_document,
        :worker_job_digest,
        :repository_ref,
        :repository_context,
        :repository_source,
        :environment_ref,
        :emisar_connection_ref,
        :emisar_account_ref,
        :emisar_rpc_url,
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
    |> validate_worker_job()
    |> validate_length(:repository_ref, min: 1, max: 1_024)
    |> validate_length(:external_ref, min: 1, max: 1_024)
    |> validate_format(:environment_ref, ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/)
    |> validate_repository_context()
    |> validate_repository_source()
    |> validate_emisar_pin()
    |> validate_workspace_task()
    |> unique_constraint([:episode_id, :generation])
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:policy, name: :episode_work_session_identity_valid)
    |> check_constraint(:repository_ref, name: :episode_work_session_repository_valid)
    |> check_constraint(:repository_context, name: :episode_work_session_repository_context_valid)
    |> check_constraint(:repository_source, name: :episode_work_session_repository_source_valid)
    |> check_constraint(:emisar_connection_ref, name: :episode_work_session_emisar_pin_valid)
    |> check_constraint(:environment_ref, name: :episode_work_session_environment_valid)
    |> check_constraint(:worker_job_document, name: :episode_work_session_worker_job_valid)
  end

  @doc """
  The authority current settings give a session no worker ever took. Its job
  is pinned again from them, so the one pinned before is dropped.
  """
  def refresh_authority(%Session{} = session, %{
        policy_digest: policy_digest,
        authority_digest: authority_digest,
        repository_context: repository_context,
        emisar: emisar
      }) do
    session
    |> cast(
      %{
        policy_digest: policy_digest,
        authority_digest: authority_digest,
        repository_context: repository_context,
        emisar_connection_ref: emisar && emisar.connection_ref,
        emisar_account_ref: emisar && emisar.account_ref,
        emisar_rpc_url: emisar && emisar.rpc_url,
        worker_job_document: nil,
        worker_job_digest: nil
      },
      [
        :policy_digest,
        :authority_digest,
        :repository_context,
        :emisar_connection_ref,
        :emisar_account_ref,
        :emisar_rpc_url,
        :worker_job_document,
        :worker_job_digest
      ]
    )
    |> validate_required([:policy_digest])
    |> validate_format(:policy_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_format(:authority_digest, ~r/\A[0-9a-f]{64}\z/)
    |> validate_worker_job()
    |> validate_repository_context()
    |> validate_emisar_pin()
    |> check_constraint(:repository_context, name: :episode_work_session_repository_context_valid)
    |> check_constraint(:emisar_connection_ref, name: :episode_work_session_emisar_pin_valid)
    |> check_constraint(:worker_job_document, name: :episode_work_session_worker_job_valid)
  end

  def pin_worker_job(session, document, digest) do
    session
    |> cast(%{worker_job_document: document, worker_job_digest: digest}, [
      :worker_job_document,
      :worker_job_digest
    ])
    |> validate_required([:worker_job_document, :worker_job_digest])
    |> validate_worker_job()
    |> check_constraint(:worker_job_document, name: :episode_work_session_worker_job_valid)
  end

  defp validate_worker_job(changeset) do
    document = get_field(changeset, :worker_job_document)
    digest = get_field(changeset, :worker_job_digest)

    case {document, digest} do
      {nil, nil} ->
        changeset

      {%{} = document, digest} when is_binary(digest) ->
        case {JobSpec.digest(document),
              document["job_ref"] == get_field(changeset, :external_ref)} do
          {{:ok, ^digest}, true} ->
            changeset

          _invalid ->
            add_error(changeset, :worker_job_document, "does not match its immutable digest")
        end

      _invalid ->
        add_error(changeset, :worker_job_document, "and digest must be pinned together")
    end
  end

  defp validate_emisar_pin(changeset) do
    fields = [:emisar_connection_ref, :emisar_account_ref, :emisar_rpc_url]
    values = Enum.map(fields, &get_field(changeset, &1))

    cond do
      Enum.all?(values, &is_nil/1) ->
        changeset

      Enum.all?(values, &is_binary/1) ->
        changeset
        |> validate_length(:emisar_connection_ref, min: 1, max: 64)
        |> validate_length(:emisar_account_ref, min: 1, max: 256)
        |> validate_length(:emisar_rpc_url, min: 9, max: 2_048)

      true ->
        add_error(changeset, :emisar_connection_ref, "must be pinned as one complete authority")
    end
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

  @doc "The session routing opens at `at` to decide a message at its generation of admission."
  @spec insert_admission(map(), DateTime.t()) :: Ecto.Changeset.t()
  def insert_admission(attributes, at) do
    %Session{}
    |> cast(attributes, @admission_fields)
    |> validate_required(@admission_fields -- [:admission_input_id])
    |> put_change(:inserted_at, at)
    |> put_change(:updated_at, at)
    |> unique_constraint(:external_ref, name: :episode_work_sessions_admission_external_ref_index)
    |> check_constraint(:execution_kind, name: :episode_work_session_owner_valid)
    |> check_constraint(:policy, name: :episode_work_session_identity_valid)
  end

  @doc "Its work is over at `at`, and cleanup plans what to keep."
  @spec close(Session.t(), DateTime.t()) :: Ecto.Changeset.t()
  def close(%Session{} = session, at),
    do: change(session, cleanup_status: :plan_pending, closed_at: at)

  @doc "A session the ready pool starts ahead of any message (`Ryker.Admission.ReadySessions`)."
  @spec reserve(map()) :: Ecto.Changeset.t()
  def reserve(attributes) do
    %Session{}
    |> change(attributes)
    |> check_constraint(:ready_state, name: :episode_work_session_ready_state_valid)
  end

  @doc "The reserved session's Coop session is open at `at`; a message may claim it."
  @spec mark_ready(Session.t(), String.t(), DateTime.t()) :: Ecto.Changeset.t()
  def mark_ready(%Session{} = session, coop_session_id, at) do
    session
    |> change(coop_session_id: coop_session_id, ready_state: :ready, updated_at: at)
    |> ready_constraints()
  end

  @doc "Coop keeps the ready session's agent running until `warm_until`."
  @spec warm(Session.t(), DateTime.t(), DateTime.t()) :: Ecto.Changeset.t()
  def warm(%Session{} = session, warm_until, at) do
    session
    |> change(warm_until: warm_until, updated_at: at)
    |> ready_constraints()
  end

  @doc "A message takes the ready session at `at`, for its generation of admission."
  @spec claim_ready(Session.t(), Ecto.UUID.t(), pos_integer(), DateTime.t()) ::
          Ecto.Changeset.t()
  def claim_ready(%Session{} = session, input_id, generation, at) do
    session
    |> change(
      admission_input_id: input_id,
      generation: generation,
      ready_state: :claimed,
      updated_at: at
    )
    |> unique_constraint([:admission_input_id, :generation],
      name: :episode_work_sessions_admission_generation_index
    )
  end

  @doc """
  No message claimed the session. Cleanup closes `coop_session_id` on its
  worker when the session became one.
  """
  @spec retire_ready(Session.t(), String.t() | nil, DateTime.t()) :: Ecto.Changeset.t()
  def retire_ready(%Session{} = session, coop_session_id, at) do
    session
    |> change(coop_session_id: coop_session_id, ready_state: :retired, updated_at: at)
    |> ready_constraints()
  end

  @doc """
  A step of the session's cleanup custody (`Ryker.Retention.Custody`). It
  is one function because every step changes cleanup fields under the same
  five checks; the custody function calling it names the step.
  """
  @spec cleanup(Session.t(), map()) :: Ecto.Changeset.t()
  def cleanup(%Session{} = session, attributes) do
    session
    |> change(attributes)
    |> check_constraint(:cleanup_status, name: :episode_work_session_cleanup_state_valid)
    |> check_constraint(:cleanup_lease_ref, name: :episode_work_session_cleanup_lease_valid)
    |> check_constraint(:discard_plan, name: :episode_work_session_discard_plan_valid)
    |> check_constraint(:cleanup_receipt, name: :episode_work_session_cleanup_receipt_valid)
    |> check_constraint(:cleanup_blocked_from, name: :episode_work_session_cleanup_blocked_valid)
  end

  defp ready_constraints(changeset) do
    changeset
    |> unique_constraint(:coop_session_id, name: :episode_work_sessions_coop_session_id_index)
    |> check_constraint(:ready_state, name: :episode_work_session_ready_state_valid)
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
