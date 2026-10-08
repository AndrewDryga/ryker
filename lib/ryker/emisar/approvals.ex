defmodule Ryker.Emisar.Approvals do
  @moduledoc """
  Durable supervision of exact Emisar approval-bound runs.

  Approval and denial happen only in Emisar. This module owns a small polling
  lease, validates the immutable run identity, and converts one terminal run
  into one trusted input that resumes the same episode. It never calls
  `run_action` and never grants mutation authority.

  Each watch registered, observed, blocked, closed or settled is announced
  after the outermost commit (`subscribe_approvals/0`), on its request's
  topics too.
  """
  alias Ryker.Crypto
  alias Ryker.Emisar.{Approval, Review, RunState}
  alias Ryker.Episodes
  alias Ryker.ErrorDetail
  alias Ryker.Ingress
  alias Ryker.Records
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.UTCDateTime
  alias Ryker.Work

  @spec ensure_registered_in_transaction(Records.Record.t()) :: :ok | {:error, term()}
  def ensure_registered_in_transaction(%Records.Record{kind: kind})
      when kind != "emisar_approval",
      do: :ok

  def ensure_registered_in_transaction(%Records.Record{} = record) do
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
    end
  end

  @doc """
  The earliest moment after `since` at which a watch of this account becomes
  claimable by the clock alone: its next look at Emisar or its retry's
  backoff is due, or the lease of a look nobody renewed runs out. Nil when no
  watch waits on the clock; a watch waiting for its task to start waiting
  waits on a change to the task, which is announced.
  """
  @spec next_due_at(String.t(), DateTime.t()) :: DateTime.t() | nil
  def next_due_at(connection_ref, %DateTime{} = since) when is_binary(connection_ref) do
    connection_ref
    |> Approval.Query.select_next_due_after(since)
    |> Repo.one()
    |> UTCDateTime.earliest()
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
    now = Repo.now!()

    with {:ok, approval} <- live_lease(connection_ref, request_id, lease_ref, now),
         :ok <- exact_run(approval, state) do
      update!(approval, %{lease_expires_at: DateTime.add(now, lease_seconds, :second)}, :quiet)
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
    end
  end

  @spec block(String.t(), String.t(), String.t(), term()) ::
          {:ok, Approval.t()} | {:error, term()}
  def block(connection_ref, request_id, lease_ref, reason) do
    with :ok <- reference(connection_ref, 64, :connection_ref),
         :ok <- reference(request_id, 80, :request_id),
         :ok <- reference(lease_ref, 1_024, :lease_ref) do
      Repo.transaction(fn -> block_locked(connection_ref, request_id, lease_ref, reason) end)
    end
  end

  # What the monitor saves when it has no usable token for the account: the
  # credential is gone, or it can no longer be decrypted. A transient failure
  # to read it is saved differently and is retried like any outage.
  @token_unavailable_codes ["credential_missing", "credential_decryption_failed"]

  @doc false
  @spec token_unavailable_codes() :: [String.t()]
  def token_unavailable_codes, do: @token_unavailable_codes

  @doc "What stopped a watch, as the code queries and the Failures page match on."
  # They matched the printed term instead (`{:emisar_http_error, 401, ...`),
  # so a change to how a reason prints would have stopped them matching
  # (2026-10-04 review).
  @spec error_code(term()) :: String.t()
  def error_code({:delivery_credentials_unavailable, reason})
      when reason in [:credential_missing, :credential_decryption_failed],
      do: Atom.to_string(reason)

  def error_code({:emisar_http_error, status, _body}) when status in 100..599,
    do: "emisar_http_#{status}"

  def error_code({:emisar_protocol_error, :review}), do: "emisar_review_unreadable"
  def error_code({:emisar_protocol_error, _detail}), do: "emisar_protocol_error"
  def error_code({:invalid_emisar_client, _detail}), do: "invalid_emisar_client"
  def error_code(:emisar_approval_identity_mismatch), do: "emisar_approval_identity_mismatch"

  def error_code({:emisar_approval_presentation_permanent, _detail}),
    do: "emisar_approval_presentation_failed"

  def error_code(_reason), do: "emisar_approval_monitoring_blocked"

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
    connection_ref
    |> Approval.Query.watches()
    |> Approval.Query.ended()
    |> Approval.Query.ordered_by_least_recently_updated()
    |> Approval.Query.limit_to(100)
    |> Approval.Query.select_ids()
    |> Repo.all()
  end

  # Nothing to close touches nothing: every write here notifies the control
  # plane, and this runs on each idle poll.
  defp close_watches([]), do: {:ok, []}

  defp close_watches(ids) do
    Repo.transaction(fn -> close_locked(ids) end)
  end

  defp close_locked(ids) do
    now = Repo.now!()

    ids
    |> lock_unleased(now)
    |> Enum.map(fn approval ->
      update!(approval, %{
        closed_at: now,
        closed_reason: :wait_ended,
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
    end
  end

  defp token_replaced_locked(connection_ref) do
    now = Repo.now!()

    (refused_watches(connection_ref) ++ unreadable_watches(connection_ref))
    |> lock_unleased(now)
    |> Enum.map(fn approval ->
      update!(approval, %{
        failure_count: 0,
        last_error: nil,
        last_error_code: nil,
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
    connection_ref
    |> Approval.Query.waited_for()
    |> Approval.Query.refused()
    |> Approval.Query.select_ids()
    |> Repo.all()
  end

  defp unreadable_watches(connection_ref) do
    connection_ref
    |> Approval.Query.waited_for()
    |> Approval.Query.failed_with(@token_unavailable_codes)
    |> Approval.Query.select_ids()
    |> Repo.all()
  end

  # The rows among `ids` still open and not being polled right now, locked.
  defp lock_unleased(ids, now) do
    ids
    |> Approval.Query.by_ids()
    |> Approval.Query.by_statuses([:monitoring, :blocked])
    |> Approval.Query.unleased_at(now)
    |> Approval.Query.ordered_by_least_recently_updated()
    |> Approval.Query.lock_next_free()
    |> Repo.all()
  end

  defp ensure_registered(%Records.Record{kind: "emisar_approval"} = record) do
    with :ok <- exact_session_authority(record) do
      case Repo.fetch(Approval.Query.by_record_id(record.id)) do
        {:error, :not_found} -> insert_approval(record)
        {:ok, %Approval{} = approval} -> exact_registration(approval, record)
      end
    end
  end

  defp exact_session_authority(record) do
    result =
      record.turn_id |> Work.Turn.Query.session_emisar_authority(record.episode_id) |> Repo.peek()

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
        id: Repo.generate_id(),
        operation_id: payload["operation_id"],
        pack_ref: payload["pack_ref"],
        record_id: record.id,
        remote_status: "pending_approval",
        request_id: payload["request_id"],
        run_id: payload["run_id"],
        runner_ref: payload["runner_ref"],
        status: :monitoring
      }
      |> Approval.Changeset.insert()
      |> Repo.insert()
      |> case do
        {:ok, approval} -> broadcast_approval_updated(approval)
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
    now = Repo.now!()

    approval = connection_ref |> Approval.Query.next_claimable(now) |> Repo.fetch()

    case approval do
      {:error, :not_found} ->
        nil

      {:ok, %Approval{} = approval} ->
        lease_ref = "emisar-approval-lease:#{Ecto.UUID.generate()}"

        # A claim only takes the lease, which no page shows. A watch is
        # claimed every few seconds for as long as its approval waits.
        approval =
          update!(
            approval,
            %{
              lease_expires_at: DateTime.add(now, lease_seconds, :second),
              lease_owner: worker_ref,
              lease_ref: lease_ref,
              next_attempt_at: nil
            },
            :quiet
          )

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
    end
  end

  defp observe_locked(connection_ref, request_id, lease_ref, state, poll_seconds) do
    now = Repo.now!()

    with {:ok, approval} <- live_lease(connection_ref, request_id, lease_ref, now),
         :ok <- exact_run(approval, state) do
      observed = %{
        failure_count: 0,
        last_error: nil,
        last_error_code: nil,
        remote_error: state.error_message,
        remote_status: state.status,
        review_digest: Review.digest(state.review),
        run_url: state.run_url
      }

      changes =
        Map.merge(observed, %{
          last_observed_at: now,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: DateTime.add(now, poll_seconds, :second)
        })

      announcement =
        if Map.take(approval, Map.keys(observed)) == observed, do: :quiet, else: :announce

      approval = update!(approval, changes, announcement)

      %{approval: approval, status: :monitoring}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp resume_terminal(connection_ref, request_id, lease_ref, state) do
    Repo.transaction(fn ->
      resume_terminal_locked(connection_ref, request_id, lease_ref, state)
    end)
  end

  defp resume_terminal_locked(connection_ref, request_id, lease_ref, state) do
    now = Repo.now!()

    with {:ok, snapshot} <- approval_row(Approval.Query.by_request(connection_ref, request_id)),
         :ok <- exact_run(snapshot, state),
         {:ok, episode} <- approval_row(Episodes.Episode.Query.by_id(snapshot.episode_id)),
         {:ok, record} <- approval_row(Records.Record.Query.by_id(snapshot.record_id)),
         {:ok, input} <- terminal_input(episode, snapshot, state, now),
         admit <- admit_command(episode, input, snapshot),
         resume <- resume_command(episode, admit, record, snapshot, now),
         {:ok, [_admitted, resumed]} <- Episodes.apply_batch_in_transaction([admit, resume]),
         {:ok, locked_record} <- lock_record(snapshot.record_id),
         {:ok, locked_approval} <- lock_approval(snapshot.id),
         {:ok, _approval} <- live_lease(locked_approval, lease_ref, now),
         :ok <- exact_run(locked_approval, state),
         :ok <- exact_wait_record(locked_record, locked_approval, record.ref),
         {:ok, answered_record} <- Repo.update(Records.Record.Changeset.answer(locked_record)),
         approval <-
           update!(locked_approval, %{
             failure_count: 0,
             last_error: nil,
             last_error_code: nil,
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
      Records.broadcast_record_updated(answered_record)
      %{approval: approval, episode: resumed.episode, record: answered_record, status: :resumed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp defer_locked(connection_ref, request_id, lease_ref, delay_seconds, reason) do
    now = Repo.now!()

    case live_lease(connection_ref, request_id, lease_ref, now) do
      {:ok, approval} ->
        update!(approval, %{
          failure_count: approval.failure_count + 1,
          last_error: ErrorDetail.detail(reason),
          last_error_code: error_code(reason),
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
    now = Repo.now!()

    case live_lease(connection_ref, request_id, lease_ref, now) do
      {:ok, approval} ->
        update!(approval, %{
          last_error: ErrorDetail.detail(reason),
          last_error_code: error_code(reason),
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
    locked =
      connection_ref
      |> Approval.Query.by_request(request_id)
      |> Approval.Query.lock_for_update()
      |> Repo.fetch()

    case locked do
      {:ok, %Approval{} = approval} -> live_lease(approval, lease_ref, now)
      {:error, :not_found} -> {:error, :emisar_approval_not_found}
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
         %Records.Record{
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
    Ingress.Input.new(%{
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
    %Episodes.Command.AdmitInput{
      actor_ref: Ingress.Input.actor_ref(input),
      destination: input.destination,
      episode_id: episode.id,
      episode_key: episode.key,
      execution_mode: episode.execution_mode,
      linked_episode_id: episode.linked_episode_id,
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: Ingress.Input.document(input),
      revision: input.revision,
      turn_ref: turn_ref(approval.request_id)
    }
  end

  defp resume_command(episode, admit, record, approval, now) do
    %Episodes.Command.ResumeWait{
      episode_key: episode.key,
      expected_wait: %{kind: :event, ref: record.ref},
      occurred_at: now,
      resolution_ref: Episodes.Command.dedupe_key(admit),
      turn_ref: turn_ref(approval.request_id)
    }
  end

  defp turn_ref(request_id) do
    digest = Crypto.sha256_hex(request_id)
    "turn:emisar-approval:#{binary_part(digest, 0, 32)}"
  end

  defp lock_record(id) do
    id
    |> Records.Record.Query.by_id()
    |> Records.Record.Query.lock_for_update()
    |> approval_row()
  end

  defp lock_approval(id),
    do: id |> Approval.Query.by_id() |> Approval.Query.lock_for_update() |> approval_row()

  # Each row a finished approval resumes from must still be there.
  defp approval_row(query) do
    with {:error, :not_found} <- Repo.fetch(query), do: {:error, :emisar_approval_not_found}
  end

  # A look that found the run as Emisar last described it, a claim and a
  # lease extension change nothing anyone sees, and a watch is looked at
  # every few seconds for as long as its approval waits: those write quietly.
  defp update!(approval, attributes, announce \\ :announce) do
    changeset = Approval.Changeset.update(approval, attributes)

    case Repo.update(changeset) do
      {:ok, approval} when announce == :quiet ->
        approval

      {:ok, approval} ->
        broadcast_approval_updated(approval)
        approval

      {:error, changeset} ->
        Repo.rollback({:emisar_approval_persistence_failed, changeset.errors})
    end
  end

  defp utc_datetime(value) when is_binary(value) do
    case UTCDateTime.parse(value) do
      {:ok, datetime} -> {:ok, datetime}
      _invalid -> {:error, {:invalid_emisar_approval, :expires_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_emisar_approval, :expires_at}}

  defp reference(value, maximum, field),
    do: Reference.check(value, field, :invalid_emisar_approval, maximum)

  defp positive(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive(_value, field), do: {:error, {:invalid_emisar_approval, field}}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to Emisar approval watches: `{:emisar_approval_updated,
  approval_id}` once a watch is registered, observed, deferred, blocked, closed
  or settled by Emisar's decision, and that change has committed.
  """
  def subscribe_approvals, do: Ryker.PubSub.subscribe(approvals_topic())

  def unsubscribe_approvals, do: Ryker.PubSub.unsubscribe(approvals_topic())

  defp approvals_topic, do: "emisar:approvals"

  @doc """
  Internal — announces, after the outermost commit, that approval watch
  `approval` changed. The operator's rearm (`Ryker.Operator.Emisar`) calls it
  too.
  """
  @spec broadcast_approval_updated(Approval.t()) :: :ok
  def broadcast_approval_updated(%Approval{id: id, episode_id: episode_id}) do
    Episodes.broadcast_episode_updated(episode_id)

    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(approvals_topic(), {:emisar_approval_updated, id})
    end)
  end
end
