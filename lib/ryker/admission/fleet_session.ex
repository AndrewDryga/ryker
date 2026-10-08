defmodule Ryker.Admission.FleetSession do
  @moduledoc """
  Durable fleet placement identity for one admission execution generation.

  Admission happens before an episode exists, so it must never fabricate a
  kernel episode merely to reach a Coop worker. These rows reuse the common
  execution-session and placement custody with an explicit `admission` kind,
  a nil episode owner, and no repository or workspace authority.

  A generation has one session: the one routing created for it, named after
  the generation, or one kept ready that the generation claimed
  (`Ryker.Admission.ReadySessions`), which keeps its own name. Both are found
  by the message and generation they serve.
  """
  alias Ryker.Crypto
  alias Ryker.Ingress
  alias Ryker.Repo
  alias Ryker.Work

  @spec ensure(Ingress.Inbox.Entry.t(), %{name: String.t(), digest: String.t()}) ::
          {:ok, Work.Session.t()} | {:error, term()}
  def ensure(%Ingress.Inbox.Entry{} = entry, %{name: policy, digest: digest}) do
    with :ok <- policy(policy, digest) do
      Repo.transaction(fn -> ensure_locked(entry, policy, digest) end)
    end
  end

  def ensure(_entry, _policy), do: {:error, :invalid_admission_fleet_session}

  @spec bind(Ingress.Inbox.Entry.t(), String.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def bind(%Ingress.Inbox.Entry{} = entry, coop_session_id) do
    with :ok <- reference(coop_session_id) do
      Repo.transaction(fn -> bind_locked(entry, coop_session_id) end)
    end
  end

  def bind(_entry, _coop_session_id), do: {:error, :invalid_admission_fleet_session}

  @spec settle(Ingress.Inbox.Entry.t(), String.t()) :: {:ok, Work.Session.t()} | {:error, term()}
  def settle(%Ingress.Inbox.Entry{} = entry, coop_session_id) do
    with :ok <- reference(coop_session_id) do
      Repo.transaction(fn -> settle_locked(entry, coop_session_id) end)
    end
  end

  def settle(_entry, _coop_session_id), do: {:error, :invalid_admission_fleet_session}

  defp ensure_locked(entry, policy, digest) do
    case fetch_and_lock_session(entry) do
      {:error, :not_found} ->
        insert_or_reload_session!(entry, policy, digest, external_ref(entry))

      {:ok, session} ->
        exact_authority(session, policy, digest)
    end
  end

  defp insert_or_reload_session!(entry, policy, digest, external_ref) do
    now = Repo.now!()

    %{
      cleanup_status: :active,
      create_generation: 1,
      execution_kind: :admission,
      admission_input_id: entry.id,
      external_ref: external_ref,
      generation: entry.execution_generation,
      id: Repo.generate_id(),
      policy: policy,
      policy_digest: digest
    }
    |> Work.Session.Changeset.insert_admission(now)
    |> Repo.insert!(on_conflict: :nothing)

    case fetch_and_lock_session(entry) do
      {:ok, session} ->
        session
        |> exact_authority(policy, digest)
        |> tap(&Work.Custody.broadcast_session_updated/1)

      {:error, :not_found} ->
        Repo.rollback(:admission_fleet_authority_conflict)
    end
  end

  defp exact_authority(
         %Work.Session{
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
    case fetch_and_lock_session(entry) do
      {:ok, %Work.Session{execution_kind: :admission, coop_session_id: nil} = session} ->
        session
        |> Work.Session.Changeset.bind(coop_session_id)
        |> Repo.update!()
        |> tap(&Work.Custody.broadcast_session_updated/1)

      {:ok,
       %Work.Session{execution_kind: :admission, coop_session_id: ^coop_session_id} = session} ->
        session

      _other ->
        Repo.rollback(:admission_fleet_session_conflict)
    end
  end

  defp settle_locked(entry, coop_session_id) do
    case fetch_and_lock_session(entry) do
      {:ok,
       %Work.Session{
         execution_kind: :admission,
         coop_session_id: ^coop_session_id,
         cleanup_status: status
       } = session}
      when status in [:plan_pending, :discard_pending, :retained, :discarded] ->
        session

      {:ok,
       %Work.Session{
         execution_kind: :admission,
         coop_session_id: ^coop_session_id,
         cleanup_status: :active
       } = session} ->
        now = Repo.now!()

        session
        |> Work.Session.Changeset.close(now)
        |> Repo.update!()
        |> tap(&Work.Custody.broadcast_session_updated/1)

      _other ->
        Repo.rollback(:admission_fleet_session_conflict)
    end
  end

  defp fetch_and_lock_session(entry) do
    entry.id
    |> Work.Session.Query.by_admission_input_id_and_generation(entry.execution_generation)
    |> Work.Session.Query.lock_for_update()
    |> Repo.fetch()
  end

  defp external_ref(%Ingress.Inbox.Entry{id: id, execution_generation: generation}),
    do: "ryker-admission:#{id}:g#{generation}"

  defp policy(name, digest) do
    if valid_ref?(name) and Crypto.sha256_hex?(digest),
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
