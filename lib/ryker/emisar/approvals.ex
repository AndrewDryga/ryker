defmodule Ryker.Emisar.Approvals do
  @moduledoc """
  Durable supervision of exact Emisar approval-bound runs.

  Approval and denial happen only in Emisar. This module owns a small polling
  lease, validates the immutable run identity, and converts one terminal run
  into one trusted input that resumes the same episode. It never calls
  `run_action` and never grants mutation authority.
  """

  import Ecto.Query

  alias Ryker.Emisar.{Approval, ApprovalChangeset, Review, RunState}
  alias Ryker.Episodes
  alias Ryker.Episodes.{Command, Episode}
  alias Ryker.Ingress.Input
  alias Ryker.Repo
  alias Ryker.State.{Record, RecordChangeset}
  alias Ryker.Work.{Session, Turn}

  @spec ensure_registered_in_transaction(Record.t()) :: :ok | {:error, term()}
  def ensure_registered_in_transaction(%Record{kind: kind}) when kind != "emisar_approval",
    do: :ok

  def ensure_registered_in_transaction(%Record{} = record) do
    if Repo.in_transaction?() do
      ensure_registered(record)
    else
      {:error, :emisar_approval_transaction_required}
    end
  end

  @spec claim_next(String.t(), String.t(), pos_integer()) ::
          {:ok, map() | nil} | {:error, term()}
  def claim_next(connection_ref, worker_ref, lease_seconds) do
    with :ok <- reference(connection_ref, 64, :connection_ref),
         :ok <- reference(worker_ref, 1_024, :worker_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_locked(connection_ref, worker_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  @spec observe(String.t(), String.t(), String.t(), RunState.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def observe(connection_ref, request_id, lease_ref, %RunState{} = state, poll_seconds) do
    with :ok <- reference(connection_ref, 64, :connection_ref),
         :ok <- reference(request_id, 80, :request_id),
         :ok <- reference(lease_ref, 1_024, :lease_ref),
         :ok <- positive(poll_seconds, :poll_seconds) do
      observe_validated(connection_ref, request_id, lease_ref, state, poll_seconds)
    end
  end

  def observe(_connection_ref, _request_id, _lease_ref, _state, _poll_seconds),
    do: {:error, {:invalid_emisar_approval_observation, :state}}

  @spec authorize_presentation(
          String.t(),
          String.t(),
          String.t(),
          RunState.t(),
          pos_integer()
        ) ::
          {:ok, Approval.t()} | {:error, term()}
  def authorize_presentation(
        connection_ref,
        request_id,
        lease_ref,
        %RunState{} = state,
        lease_seconds
      ) do
    with :ok <- reference(connection_ref, 64, :connection_ref),
         :ok <- reference(request_id, 80, :request_id),
         :ok <- reference(lease_ref, 1_024, :lease_ref),
         :ok <- positive(lease_seconds, :lease_seconds) do
      Repo.transaction(fn ->
        authorize_presentation_locked(
          connection_ref,
          request_id,
          lease_ref,
          state,
          lease_seconds
        )
      end)
      |> transaction_result()
    end
  end

  def authorize_presentation(
        _connection_ref,
        _request_id,
        _lease_ref,
        _state,
        _lease_seconds
      ),
      do: {:error, {:invalid_emisar_approval_observation, :state}}

  defp authorize_presentation_locked(
         connection_ref,
         request_id,
         lease_ref,
         state,
         lease_seconds
       ) do
    now = database_now!()

    with {:ok, approval} <- live_lease(connection_ref, request_id, lease_ref, now),
         :ok <- exact_run(approval, state) do
      update!(approval, %{lease_expires_at: DateTime.add(now, lease_seconds, :second)})
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec defer(String.t(), String.t(), String.t(), pos_integer(), term()) ::
          {:ok, Approval.t()} | {:error, term()}
  def defer(connection_ref, request_id, lease_ref, delay_seconds, reason) do
    with :ok <- reference(connection_ref, 64, :connection_ref),
         :ok <- reference(request_id, 80, :request_id),
         :ok <- reference(lease_ref, 1_024, :lease_ref),
         :ok <- positive(delay_seconds, :delay_seconds) do
      Repo.transaction(fn ->
        defer_locked(connection_ref, request_id, lease_ref, delay_seconds, reason)
      end)
      |> transaction_result()
    end
  end

  @spec block(String.t(), String.t(), String.t(), term()) ::
          {:ok, Approval.t()} | {:error, term()}
  def block(connection_ref, request_id, lease_ref, reason) do
    with :ok <- reference(connection_ref, 64, :connection_ref),
         :ok <- reference(request_id, 80, :request_id),
         :ok <- reference(lease_ref, 1_024, :lease_ref) do
      Repo.transaction(fn -> block_locked(connection_ref, request_id, lease_ref, reason) end)
      |> transaction_result()
    end
  end

  @spec get_by_request_id(String.t(), String.t()) :: Approval.t() | nil
  def get_by_request_id(connection_ref, request_id)
      when is_binary(connection_ref) and is_binary(request_id),
      do:
        Repo.one(
          from(approval in Approval,
            where:
              approval.connection_ref == ^connection_ref and approval.request_id == ^request_id
          )
        )

  def get_by_request_id(_connection_ref, _request_id), do: nil

  # What the monitor saves when it has no usable token for the account: the
  # credential is gone, or it can no longer be decrypted. A transient failure
  # to read it is saved differently and is retried like any outage.
  @token_unavailable_errors [
    "{:delivery_credentials_unavailable, :credential_missing}",
    "{:delivery_credentials_unavailable, :credential_decryption_failed}"
  ]

  @doc false
  @spec token_unavailable_errors() :: [String.t()]
  def token_unavailable_errors, do: @token_unavailable_errors

  @doc """
  Closes this account's approval watches that nothing waits for any more.

  A watch ends for good once its task is closed or its wait was answered. A
  blocked one could only be refused on every retry and sat on the Failures
  page for good, and a monitoring one was never claimed again. Each is closed
  with the reason and kept as history, never deleted. A watch whose task has
  not started waiting yet is left alone: its turn registers it before the
  delivered result starts the wait. Returns the closed request IDs.
  """
  @spec close_ended(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def close_ended(connection_ref) do
    with :ok <- reference(connection_ref, 64, :connection_ref) do
      connection_ref |> ended_watches() |> close_watches()
    end
  end

  defp ended_watches(connection_ref) do
    Repo.all(
      from([approval, record, episode] in watches(connection_ref),
        where: approval.status in [:monitoring, :blocked],
        where: record.status != :open or episode.state == :cancelled,
        order_by: [asc: approval.updated_at, asc: approval.id],
        limit: 100,
        select: approval.id
      )
    )
  end

  # Nothing to close touches nothing: every write here notifies the control
  # plane, and this runs on each idle poll.
  defp close_watches([]), do: {:ok, []}

  defp close_watches(ids) do
    Repo.transaction(fn -> close_locked(ids) end)
    |> transaction_result()
  end

  defp close_locked(ids) do
    now = database_now!()

    ids
    |> lock_unleased(now)
    |> Enum.map(fn approval ->
      update!(approval, %{
        closed_at: now,
        closed_reason: "wait_ended",
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :closed
      }).request_id
    end)
  end

  @doc """
  Clears what a replaced token fixes, for one account.

  A watch Emisar stopped because it refused the old token is watched again,
  and a watch that could not read its token is checked now rather than after
  the backoff it had reached. Each still needs a task waiting for it; the next
  poll with a still-refused token blocks it again. Returns how many changed.
  """
  @spec token_replaced(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def token_replaced(connection_ref) do
    with :ok <- reference(connection_ref, 64, :connection_ref) do
      Repo.transaction(fn -> token_replaced_locked(connection_ref) end)
      |> transaction_result()
    end
  end

  defp token_replaced_locked(connection_ref) do
    now = database_now!()

    (refused_watches(connection_ref) ++ unreadable_watches(connection_ref))
    |> lock_unleased(now)
    |> Enum.map(fn approval ->
      update!(approval, %{
        failure_count: 0,
        last_error: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :monitoring
      })
    end)
    |> length()
  end

  defp refused_watches(connection_ref) do
    Repo.all(
      from([approval, _record, _episode] in waited_for(connection_ref),
        where: approval.status == :blocked,
        where:
          like(approval.last_error, "{:emisar_http_error, 401,%") or
            like(approval.last_error, "{:emisar_http_error, 403,%"),
        select: approval.id
      )
    )
  end

  defp unreadable_watches(connection_ref) do
    Repo.all(
      from([approval, _record, _episode] in waited_for(connection_ref),
        where: approval.status == :monitoring,
        where: approval.last_error in ^@token_unavailable_errors,
        select: approval.id
      )
    )
  end

  defp watches(connection_ref) do
    from(approval in Approval,
      join: record in Record,
      on: record.id == approval.record_id and record.episode_id == approval.episode_id,
      join: episode in Episode,
      on: episode.id == approval.episode_id,
      where: approval.connection_ref == ^connection_ref
    )
  end

  # This account's watches that a task is waiting for right now.
  defp waited_for(connection_ref) do
    from([approval, record, episode] in watches(connection_ref),
      where: record.kind == "emisar_approval" and record.status == :open,
      where:
        episode.state == :waiting_for_event and episode.owner_kind == :event and
          episode.owner_ref == record.ref
    )
  end

  # The rows among `ids` still open and not being polled right now, locked.
  defp lock_unleased(ids, now) do
    Repo.all(
      from(approval in Approval,
        where: approval.id in ^ids and approval.status in [:monitoring, :blocked],
        where: is_nil(approval.lease_ref) or approval.lease_expires_at <= ^now,
        order_by: [asc: approval.updated_at, asc: approval.id],
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  defp ensure_registered(%Record{kind: "emisar_approval"} = record) do
    with :ok <- exact_session_authority(record) do
      case Repo.one(from(approval in Approval, where: approval.record_id == ^record.id)) do
        nil -> insert_approval(record)
        %Approval{} = approval -> exact_registration(approval, record)
      end
    end
  end

  defp exact_session_authority(record) do
    result =
      Repo.one(
        from(turn in Turn,
          join: session in Session,
          on: session.id == turn.session_id and session.episode_id == turn.episode_id,
          where: turn.id == ^record.turn_id and turn.episode_id == ^record.episode_id,
          select: {
            session.emisar_connection_ref,
            session.emisar_account_ref,
            session.emisar_rpc_url
          }
        )
      )

    expected = {
      record.payload["connection_ref"],
      record.payload["account_ref"],
      record.payload["rpc_url"]
    }

    if result == expected and Enum.all?(Tuple.to_list(expected), &is_binary/1),
      do: :ok,
      else: {:error, :emisar_approval_connection_mismatch}
  end

  defp insert_approval(record) do
    payload = record.payload

    with {:ok, expires_at} <- utc_datetime(payload["expires_at"]) do
      %{
        action_id: payload["action_id"],
        approval_url: payload["approval_url"],
        connection_ref: payload["connection_ref"],
        episode_id: record.episode_id,
        expires_at: expires_at,
        id: Ecto.UUID.generate(),
        operation_id: payload["operation_id"],
        pack_ref: payload["pack_ref"],
        record_id: record.id,
        remote_status: "pending_approval",
        request_id: payload["request_id"],
        run_id: payload["run_id"],
        runner_ref: payload["runner_ref"],
        status: :monitoring
      }
      |> ApprovalChangeset.insert()
      |> Repo.insert()
      |> case do
        {:ok, _approval} -> :ok
        {:error, changeset} -> {:error, {:emisar_approval_persistence_failed, changeset.errors}}
      end
    end
  end

  defp exact_registration(approval, record) do
    payload = record.payload

    actual = %{
      "action_id" => approval.action_id,
      "approval_url" => approval.approval_url,
      "connection_ref" => approval.connection_ref,
      "episode_id" => approval.episode_id,
      "expires_at" => DateTime.to_iso8601(approval.expires_at),
      "operation_id" => approval.operation_id,
      "pack_ref" => approval.pack_ref,
      "request_id" => approval.request_id,
      "run_id" => approval.run_id,
      "runner_ref" => approval.runner_ref,
      "status" => "pending_approval"
    }

    expected =
      payload
      |> Map.drop(["account_ref", "rpc_url"])
      |> Map.put("episode_id", record.episode_id)

    if actual == expected, do: :ok, else: {:error, :emisar_approval_registration_conflict}
  end

  defp claim_locked(connection_ref, worker_ref, lease_seconds) do
    now = database_now!()

    approval =
      Repo.one(
        from(approval in Approval,
          where: approval.id in subquery(eligible_approval_ids(connection_ref, now)),
          order_by: [
            asc_nulls_first: approval.next_attempt_at,
            asc: approval.inserted_at,
            asc: approval.id
          ],
          limit: 1,
          lock: "FOR UPDATE SKIP LOCKED"
        )
      )

    case approval do
      nil ->
        nil

      %Approval{} = approval ->
        lease_ref = "emisar-approval-lease:#{Ecto.UUID.generate()}"

        approval =
          update!(approval, %{
            lease_expires_at: DateTime.add(now, lease_seconds, :second),
            lease_owner: worker_ref,
            lease_ref: lease_ref,
            next_attempt_at: nil
          })

        %{approval: approval, lease_ref: lease_ref}
    end
  end

  defp observe_validated(connection_ref, request_id, lease_ref, state, poll_seconds) do
    if RunState.terminal?(state) do
      resume_terminal(connection_ref, request_id, lease_ref, state)
    else
      Repo.transaction(fn ->
        observe_locked(connection_ref, request_id, lease_ref, state, poll_seconds)
      end)
      |> transaction_result()
    end
  end

  defp eligible_approval_ids(connection_ref, now) do
    from(approval in Approval,
      join: record in Record,
      on: record.id == approval.record_id and record.episode_id == approval.episode_id,
      join: episode in Episode,
      on: episode.id == approval.episode_id,
      where: approval.status == :monitoring,
      where: approval.connection_ref == ^connection_ref,
      where: record.kind == "emisar_approval" and record.status == :open,
      where:
        episode.state == :waiting_for_event and episode.owner_kind == :event and
          episode.owner_ref == record.ref,
      where: is_nil(approval.next_attempt_at) or approval.next_attempt_at <= ^now,
      where: is_nil(approval.lease_ref) or approval.lease_expires_at <= ^now,
      select: approval.id
    )
  end

  defp observe_locked(connection_ref, request_id, lease_ref, state, poll_seconds) do
    now = database_now!()

    with {:ok, approval} <- live_lease(connection_ref, request_id, lease_ref, now),
         :ok <- exact_run(approval, state) do
      approval =
        update!(approval, %{
          failure_count: 0,
          last_error: nil,
          last_observed_at: now,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: DateTime.add(now, poll_seconds, :second),
          remote_error: state.error_message,
          remote_status: state.status,
          review_digest: Review.digest(state.review),
          run_url: state.run_url
        })

      %{approval: approval, status: :monitoring}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_terminal(connection_ref, request_id, lease_ref, state) do
    Repo.transaction(fn ->
      resume_terminal_locked(connection_ref, request_id, lease_ref, state)
    end)
    |> transaction_result()
  end

  defp resume_terminal_locked(connection_ref, request_id, lease_ref, state) do
    now = database_now!()

    with %Approval{} = snapshot <-
           Repo.one(
             from(approval in Approval,
               where:
                 approval.connection_ref == ^connection_ref and
                   approval.request_id == ^request_id
             )
           ),
         :ok <- exact_run(snapshot, state),
         %Episode{} = episode <- Repo.get(Episode, snapshot.episode_id),
         %Record{} = record <- Repo.get(Record, snapshot.record_id),
         {:ok, input} <- terminal_input(episode, snapshot, state, now),
         admit <- admit_command(episode, input, snapshot),
         resume <- resume_command(episode, admit, record, snapshot, now),
         {:ok, [_admitted, resumed]} <- Episodes.apply_batch_in_transaction([admit, resume]),
         %Record{} = locked_record <- lock_record(snapshot.record_id),
         %Approval{} = locked_approval <- lock_approval(snapshot.id),
         {:ok, _approval} <- live_lease(locked_approval, lease_ref, now),
         :ok <- exact_run(locked_approval, state),
         :ok <- exact_wait_record(locked_record, locked_approval, record.ref),
         {:ok, answered_record} <- locked_record |> RecordChangeset.answer() |> Repo.update(),
         approval <-
           update!(locked_approval, %{
             failure_count: 0,
             last_error: nil,
             last_observed_at: now,
             lease_expires_at: nil,
             lease_owner: nil,
             lease_ref: nil,
             next_attempt_at: nil,
             remote_error: state.error_message,
             remote_status: state.status,
             resumed_at: now,
             review_digest: Review.digest(state.review),
             run_url: state.run_url,
             status: :resumed,
             terminal_at: now
           }) do
      %{approval: approval, episode: resumed.episode, record: answered_record, status: :resumed}
    else
      nil -> Repo.rollback(:emisar_approval_not_found)
      {:error, reason} -> Repo.rollback(reason)
      %Record{} -> Repo.rollback(:emisar_approval_record_stale)
      %Approval{} -> Repo.rollback(:emisar_approval_lease_lost)
    end
  end

  defp defer_locked(connection_ref, request_id, lease_ref, delay_seconds, reason) do
    now = database_now!()

    case live_lease(connection_ref, request_id, lease_ref, now) do
      {:ok, approval} ->
        update!(approval, %{
          failure_count: approval.failure_count + 1,
          last_error: bounded_error(reason),
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: DateTime.add(now, delay_seconds, :second)
        })

      {:error, defer_reason} ->
        Repo.rollback(defer_reason)
    end
  end

  defp block_locked(connection_ref, request_id, lease_ref, reason) do
    now = database_now!()

    case live_lease(connection_ref, request_id, lease_ref, now) do
      {:ok, approval} ->
        update!(approval, %{
          last_error: bounded_error(reason),
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: nil,
          status: :blocked
        })

      {:error, block_reason} ->
        Repo.rollback(block_reason)
    end
  end

  defp live_lease(connection_ref, request_id, lease_ref, now)
       when is_binary(connection_ref) and is_binary(request_id) do
    case Repo.one(
           from(approval in Approval,
             where:
               approval.connection_ref == ^connection_ref and approval.request_id == ^request_id,
             lock: "FOR UPDATE"
           )
         ) do
      %Approval{} = approval -> live_lease(approval, lease_ref, now)
      nil -> {:error, :emisar_approval_not_found}
    end
  end

  defp live_lease(
         %Approval{
           lease_expires_at: %DateTime{} = expires_at,
           lease_ref: lease_ref,
           status: :monitoring
         } = approval,
         lease_ref,
         now
       ) do
    if DateTime.compare(expires_at, now) == :gt,
      do: {:ok, approval},
      else: {:error, :emisar_approval_lease_expired}
  end

  defp live_lease(_approval, _lease_ref, _now), do: {:error, :emisar_approval_lease_lost}

  defp exact_run(approval, state) do
    if approval.run_id == state.run_id and approval.operation_id == state.operation_id and
         approval.action_id == state.action_id and approval.pack_ref == state.pack_ref and
         approval.runner_ref == state.runner_ref,
       do: :ok,
       else: {:error, :emisar_approval_identity_mismatch}
  end

  defp exact_wait_record(
         %Record{
           episode_id: episode_id,
           id: record_id,
           kind: "emisar_approval",
           ref: ref,
           status: :open
         },
         %Approval{episode_id: episode_id, record_id: record_id},
         ref
       ),
       do: :ok

  defp exact_wait_record(_record, _approval, _ref),
    do: {:error, :emisar_approval_record_stale}

  defp terminal_input(episode, approval, state, now) do
    Input.new(%{
      actor: %{kind: :system, ref: "emisar-approval-monitor"},
      content: %{
        "action_id" => state.action_id,
        "approval_request_id" => approval.request_id,
        "error_message" => state.error_message,
        "kind" => "emisar_approval_terminal",
        "operation_id" => state.operation_id,
        "pack_ref" => state.pack_ref,
        "required_next_operation" => "wait_for_run",
        "run_id" => state.run_id,
        "run_url" => state.run_url,
        "runner_ref" => state.runner_ref,
        "status" => state.status,
        "verification" =>
          "Inspect exactly this terminal run with wait_for_run. Never call run_action or create a replacement run. Verify the intended effect with read-only evidence when possible."
      },
      destination: %{
        conversation_ref: episode.destination_conversation_ref,
        thread_ref: episode.destination_thread_ref,
        transport: episode.destination_transport
      },
      event_kind: :event,
      event_ref: "emisar-approval-terminal:#{approval.connection_ref}:#{approval.request_id}",
      native_input_id: "emisar-approval:#{approval.connection_ref}:#{approval.request_id}",
      occurred_at: now,
      occurred_at_source: :ingress,
      revision: 1,
      source: %{kind: "system", ref: "emisar"},
      source_capabilities: %{},
      source_item_ref: nil
    })
  end

  defp admit_command(episode, input, approval) do
    %Command.AdmitInput{
      actor_ref: Input.actor_ref(input),
      destination: input.destination,
      episode_id: episode.id,
      episode_key: episode.key,
      execution_mode: episode.execution_mode,
      linked_episode_id: episode.linked_episode_id,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: Input.document(input),
      revision: input.revision,
      turn_ref: turn_ref(approval.request_id)
    }
  end

  defp resume_command(episode, admit, record, approval, now) do
    %Command.ResumeWait{
      episode_key: episode.key,
      expected_wait: %{kind: :event, ref: record.ref},
      occurred_at: now,
      resolution_ref: Command.dedupe_key(admit),
      turn_ref: turn_ref(approval.request_id)
    }
  end

  defp turn_ref(request_id) do
    digest = :crypto.hash(:sha256, request_id) |> Base.encode16(case: :lower)
    "turn:emisar-approval:#{binary_part(digest, 0, 32)}"
  end

  defp lock_record(id),
    do: Repo.one(from(record in Record, where: record.id == ^id, lock: "FOR UPDATE"))

  defp lock_approval(id),
    do: Repo.one(from(approval in Approval, where: approval.id == ^id, lock: "FOR UPDATE"))

  defp update!(approval, attributes) do
    case approval |> ApprovalChangeset.update(attributes) |> Repo.update() do
      {:ok, approval} ->
        approval

      {:error, changeset} ->
        Repo.rollback({:emisar_approval_persistence_failed, changeset.errors})
    end
  end

  defp utc_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_emisar_approval, :expires_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_emisar_approval, :expires_at}}

  defp database_now! do
    case Repo.query("SELECT clock_timestamp()") do
      {:ok, %{rows: [[%DateTime{} = now]]}} -> now
      {:error, reason} -> Repo.rollback({:emisar_approval_clock_failed, reason})
    end
  end

  defp bounded_error(reason) do
    value = inspect(reason, limit: 50, printable_limit: 4_096)
    if byte_size(value) <= 4_096, do: value, else: String.byte_slice(value, 0, 4_096)
  end

  defp reference(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_emisar_approval, field}}
  end

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_emisar_approval, field}}

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
