defmodule Ryker.Admission.FleetSession do
  @moduledoc """
  Durable fleet placement identity for one admission execution generation.

  Admission happens before an episode exists, so it must never fabricate a
  kernel episode merely to reach a Coop worker. These rows reuse the common
  execution-session and placement custody with an explicit `admission` kind,
  a nil episode owner, and no repository or workspace authority.
  """

  import Ecto.Query

  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.Session

  @spec ensure(Entry.t(), %{name: String.t(), digest: String.t()}) ::
          {:ok, Session.t()} | {:error, term()}
  def ensure(%Entry{} = entry, %{name: policy, digest: digest}) do
    with :ok <- policy(policy, digest) do
      Repo.transaction(fn -> ensure_locked(entry, policy, digest) end)
    end
  end

  def ensure(_entry, _policy), do: {:error, :invalid_admission_fleet_session}

  @spec bind(Entry.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def bind(%Entry{} = entry, coop_session_id) do
    with :ok <- reference(coop_session_id) do
      Repo.transaction(fn -> bind_locked(entry, coop_session_id) end)
    end
  end

  def bind(_entry, _coop_session_id), do: {:error, :invalid_admission_fleet_session}

  @spec settle(Entry.t(), String.t()) :: {:ok, Session.t()} | {:error, term()}
  def settle(%Entry{} = entry, coop_session_id) do
    with :ok <- reference(coop_session_id) do
      Repo.transaction(fn -> settle_locked(entry, coop_session_id) end)
    end
  end

  def settle(_entry, _coop_session_id), do: {:error, :invalid_admission_fleet_session}

  defp ensure_locked(entry, policy, digest) do
    external_ref = external_ref(entry)

    case lock_session(external_ref) do
      nil -> insert_or_reload_session!(entry, policy, digest, external_ref)
      %Session{} = session -> exact_authority(session, policy, digest)
    end
  end

  defp insert_or_reload_session!(entry, policy, digest, external_ref) do
    now = Repo.now!()

    %Session{}
    |> Ecto.Changeset.cast(
      %{
        cleanup_status: :active,
        create_generation: 1,
        execution_kind: :admission,
        admission_input_id: entry.id,
        external_ref: external_ref,
        generation: entry.execution_generation,
        id: Ecto.UUID.generate(),
        policy: policy,
        policy_digest: digest
      },
      [
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
    )
    |> Ecto.Changeset.validate_required([
      :cleanup_status,
      :create_generation,
      :execution_kind,
      :external_ref,
      :generation,
      :id,
      :policy,
      :policy_digest
    ])
    |> Ecto.Changeset.put_change(:inserted_at, now)
    |> Ecto.Changeset.put_change(:updated_at, now)
    |> Ecto.Changeset.unique_constraint(:external_ref,
      name: :episode_work_sessions_admission_external_ref_index
    )
    |> Ecto.Changeset.check_constraint(:execution_kind,
      name: :episode_work_session_owner_valid
    )
    |> Ecto.Changeset.check_constraint(:policy, name: :episode_work_session_identity_valid)
    |> Repo.insert!(on_conflict: :nothing)

    external_ref
    |> lock_session()
    |> exact_authority(policy, digest)
  end

  defp exact_authority(
         %Session{
           cleanup_status: :active,
           execution_kind: :admission,
           episode_id: nil,
           policy: policy,
           policy_digest: digest
         } = session,
         policy,
         digest
       ),
       do: session

  defp exact_authority(_session, _policy, _digest),
    do: Repo.rollback(:admission_fleet_authority_conflict)

  defp bind_locked(entry, coop_session_id) do
    case lock_session(external_ref(entry)) do
      %Session{execution_kind: :admission, coop_session_id: nil} = session ->
        session
        |> Ecto.Changeset.change(%{coop_session_id: coop_session_id})
        |> Ecto.Changeset.unique_constraint(:coop_session_id)
        |> Repo.update!()

      %Session{execution_kind: :admission, coop_session_id: ^coop_session_id} = session ->
        session

      _other ->
        Repo.rollback(:admission_fleet_session_conflict)
    end
  end

  defp settle_locked(entry, coop_session_id) do
    case lock_session(external_ref(entry)) do
      %Session{
        execution_kind: :admission,
        coop_session_id: ^coop_session_id,
        cleanup_status: :discarded
      } = session ->
        session

      %Session{
        execution_kind: :admission,
        coop_session_id: ^coop_session_id,
        cleanup_status: :active
      } = session ->
        now = Repo.now!()

        session
        |> Ecto.Changeset.change(%{
          cleanup_status: :discarded,
          closed_at: now,
          discarded_at: now
        })
        |> Repo.update!()

      _other ->
        Repo.rollback(:admission_fleet_session_conflict)
    end
  end

  defp lock_session(external_ref) do
    Repo.one(
      from(session in Session,
        where: session.external_ref == ^external_ref,
        lock: "FOR UPDATE"
      )
    )
  end

  defp external_ref(%Entry{id: id, execution_generation: generation}),
    do: "ryker-admission:#{id}:g#{generation}"

  defp policy(name, digest) do
    if valid_ref?(name) and is_binary(digest) and Regex.match?(~r/\A[0-9a-f]{64}\z/, digest),
      do: :ok,
      else: {:error, :invalid_admission_fleet_session}
  end

  defp reference(value) do
    if valid_ref?(value), do: :ok, else: {:error, :invalid_admission_fleet_session}
  end

  defp valid_ref?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end
end
