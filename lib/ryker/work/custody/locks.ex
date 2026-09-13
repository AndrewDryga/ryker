defmodule Ryker.Work.Custody.Locks do
  @moduledoc """
  Row locking, lease checks, and argument validation shared by the custody seams.

  The row helpers lock the episode owner, then the session, then the turn, so
  every seam takes rows in the same order; the lease helpers prove a worker
  still holds its opaque lease before a seam writes. The validators map each
  malformed argument to `{:error, {:invalid_work_custody, field}}` so the seams
  share one error vocabulary. Nothing here starts a transaction.
  """

  import Ecto.Query

  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.Work.{Session, Turn}

  @maximum_candidate_bytes 256 * 1_024

  @doc false
  def leased!(episode_id, turn_ref, lease_ref) do
    case turn_for_lease(episode_id, turn_ref, lease_ref) do
      {:ok, session, turn} -> {session, turn}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @doc false
  def turn_for_lease(episode_id, turn_ref, lease_ref) do
    with %Turn{} = identity <- turn_identity(episode_id, turn_ref),
         {:ok, _episode} <- lock_current_episode_owner(episode_id, identity),
         {:ok, session} <- lock_session(episode_id, identity.session_id),
         {:ok, turn} <- leased_turn(episode_id, turn_ref, lease_ref) do
      {:ok, session, turn}
    else
      nil -> {:error, :work_turn_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def turn_identity(episode_id, turn_ref) do
    Repo.one(
      from(turn in Turn,
        where: turn.episode_id == ^episode_id and turn.turn_ref == ^turn_ref
      )
    )
  end

  @doc false
  def lock_turn(episode_id, turn_ref) do
    case Repo.one(
           from(turn in Turn,
             where: turn.episode_id == ^episode_id and turn.turn_ref == ^turn_ref,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :work_turn_not_found}
      %Turn{} = turn -> {:ok, turn}
    end
  end

  defp leased_turn(episode_id, turn_ref, lease_ref) do
    case Repo.one(
           from(turn in Turn,
             where:
               turn.episode_id == ^episode_id and turn.turn_ref == ^turn_ref and
                 turn.lease_expires_at > fragment("clock_timestamp()"),
             lock: "FOR UPDATE"
           )
         ) do
      nil ->
        {:error, :work_turn_not_found}

      %Turn{status: status, lease_ref: ^lease_ref} = turn
      when status in [:pending, :cancel_pending, :delivery_pending] ->
        {:ok, turn}

      %Turn{} ->
        {:error, :work_lease_lost}
    end
  end

  defp lock_current_episode_owner(episode_id, %Turn{status: :pending, turn_ref: owner_ref}) do
    lock_episode_owner(episode_id, :turn, owner_ref)
  end

  defp lock_current_episode_owner(
         episode_id,
         %Turn{status: :cancel_pending, turn_ref: owner_ref}
       ) do
    lock_episode_owner(episode_id, :turn, owner_ref)
  end

  defp lock_current_episode_owner(
         episode_id,
         %Turn{status: :delivery_pending, delivery_ref: owner_ref}
       )
       when is_binary(owner_ref) do
    lock_episode_owner(episode_id, :delivery, owner_ref)
  end

  defp lock_current_episode_owner(_episode_id, %Turn{}),
    do: {:error, :work_turn_not_claimable}

  @doc false
  def lock_episode_owner(episode_id, owner_kind, owner_ref) do
    case Repo.one(
           from(episode in Episode,
             where:
               episode.id == ^episode_id and episode.state == :working and
                 episode.owner_kind == ^owner_kind and episode.owner_ref == ^owner_ref,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :work_episode_owner_lost}
      %Episode{} = episode -> {:ok, episode}
    end
  end

  @doc false
  def lock_session(episode_id, session_id) do
    case Repo.one(
           from(session in Session,
             where: session.episode_id == ^episode_id and session.id == ^session_id,
             lock: "FOR UPDATE"
           )
         ) do
      nil -> {:error, :work_session_not_found}
      %Session{} = session -> {:ok, session}
    end
  end

  @doc false
  def lock_turn_after_episode(episode_id, turn_ref) do
    with %Turn{} = identity <- turn_identity(episode_id, turn_ref),
         {:ok, session} <- lock_session(episode_id, identity.session_id),
         {:ok, turn} <- lock_turn(episode_id, turn_ref) do
      {:ok, session, turn}
    else
      nil -> {:error, :work_turn_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def turn_owner?(episode, turn),
    do:
      episode.state == :working and episode.owner_kind == :turn and
        episode.owner_ref == turn.turn_ref

  @doc false
  def current_turn_owner(episode, turn) do
    if turn_owner?(episode, turn),
      do: :ok,
      else: {:error, :work_episode_owner_lost}
  end

  @doc false
  def current_turn_lease(turn, lease_ref, now) do
    if current_lease?(turn, lease_ref, now), do: :ok, else: {:error, :work_lease_lost}
  end

  @doc false
  def current_lease?(turn, lease_ref, now) do
    turn.lease_ref == lease_ref and match?(%DateTime{}, turn.lease_expires_at) and
      DateTime.compare(turn.lease_expires_at, now) == :gt
  end

  @doc false
  def exact_episode(%Episode{id: episode_id}, episode_id), do: :ok

  def exact_episode(%Episode{id: actual}, expected),
    do: {:error, {:work_episode_identity_conflict, actual, expected}}

  @doc false
  def episode_for_result!(episode_key) do
    Repo.one!(from(episode in Episode, where: episode.key == ^episode_key))
  end

  @doc false
  def unwrap_or_rollback({:ok, record}, _kind), do: record

  def unwrap_or_rollback({:error, changeset}, kind) do
    Repo.rollback({:persistence_failed, kind, changeset.errors})
  end

  @doc false
  def persistence_result({:ok, record}, _kind), do: {:ok, record}

  def persistence_result({:error, changeset}, kind) do
    {:error, {:persistence_failed, kind, changeset.errors}}
  end

  @doc false
  def reference(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_work_custody, field}}
  end

  @doc false
  def optional_reference(nil, _field), do: :ok
  def optional_reference(value, field), do: reference(value, field)

  @doc false
  def optional_sha256(nil, _field), do: :ok
  def optional_sha256(value, field), do: sha256(value, field)

  @doc false
  def artifact_refs(refs) when is_list(refs) and length(refs) <= 5 do
    if Enum.uniq(refs) == refs and Enum.all?(refs, &valid_reference?/1),
      do: :ok,
      else: {:error, {:invalid_work_custody, :artifact_refs}}
  end

  def artifact_refs(_refs), do: {:error, {:invalid_work_custody, :artifact_refs}}

  defp valid_reference?(value) when is_binary(value),
    do:
      byte_size(value) in 1..256 and String.valid?(value) and
        :binary.match(value, <<0>>) == :nomatch

  defp valid_reference?(_value), do: false

  @doc false
  def bounded_text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_work_custody, field}}
  end

  @doc false
  def candidate(value) do
    if is_binary(value) and String.valid?(value) and
         byte_size(value) in 1..@maximum_candidate_bytes and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_work_custody, :candidate}}
  end

  @doc false
  def sha256(value, field) do
    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: :ok,
      else: {:error, {:invalid_work_custody, field}}
  end

  @doc false
  def optional_candidate_identity(nil, nil), do: :ok

  def optional_candidate_identity(candidate_sha256, candidate_attempt)
      when is_binary(candidate_sha256) and is_integer(candidate_attempt) do
    case sha256(candidate_sha256, :expected_candidate_sha256) do
      :ok -> positive_integer(candidate_attempt, :expected_candidate_attempt)
      {:error, _reason} = error -> error
    end
  end

  def optional_candidate_identity(_candidate_sha256, _candidate_attempt),
    do: {:error, {:invalid_work_custody, :expected_candidate_identity}}

  @doc false
  def callback(value) when is_function(value, 0), do: :ok
  def callback(_value), do: {:error, {:invalid_work_custody, :callback}}

  @doc false
  def exact_sha256(value, digest) do
    if digest == digest(value),
      do: :ok,
      else: {:error, {:invalid_work_custody, :candidate_sha256}}
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @doc false
  def uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_work_custody, field}}
    end
  end

  @doc false
  def positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  def positive_integer(_value, field), do: {:error, {:invalid_work_custody, field}}

  @doc false
  def non_negative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  def non_negative_integer(_value, field),
    do: {:error, {:invalid_work_custody, field}}

  @doc false
  def measurement(value) when is_map(value), do: :ok
  def measurement(_value), do: {:error, {:invalid_work_custody, :measurement}}

  @doc false
  def transaction_open do
    if Repo.in_transaction?(),
      do: :ok,
      else: {:error, :work_transaction_required}
  end
end
