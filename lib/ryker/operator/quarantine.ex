defmodule Ryker.Operator.Quarantine do
  @moduledoc """
  Explicit, audited retirement of a quarantined worker record. The worker keeps
  the copy and its runtime state. No episode is resumed and no file is deleted.

  Request queues the exact revision on the exact placement. Settle reads that
  durable command's receipt; neither function waits for a worker inside a lock.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet
  alias Ryker.Episodes
  alias Ryker.Maps
  alias Ryker.Operator.{Action, Actions}
  alias Ryker.Publication
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Retention
  alias Ryker.UTCDateTime
  alias Ryker.Work

  @fields ~w(action_ref actor_ref expected_revision inspection_command_id placement_generation placement_id remote_session_id session_id)a
  @refusals ~w(revision_conflict invalid_session_state)

  @doc """
  Records a retirement intent and queues its worker command. Repeating the same
  action returns its saved intent. Changed identity, unfinished work and copies
  without sufficient recovery evidence are refused before a command is queued.
  """
  @spec request(map()) :: {:ok, map()} | {:error, term()}
  def request(attributes) when is_map(attributes) do
    with :ok <- validate(attributes) do
      audit = %{
        action: :update,
        action_ref: attributes.action_ref,
        actor_ref: attributes.actor_ref,
        kind: "quarantine_recovery",
        resource_ref: attributes.session_id,
        request: Map.new(attributes, fn {key, value} -> {Atom.to_string(key), value} end)
      }

      Actions.run(audit, fn -> prepare(attributes) end)
    end
  end

  def request(_attributes), do: {:error, :invalid_quarantine_recovery}

  @doc """
  Reconciles a requested retirement from its authenticated durable worker result.
  Returns `{:ok, :waiting}` while it is out, a saved or duplicate audit receipt
  when settled, or an error for uncertain or mismatched receipts. Refusal leaves
  the copy's prior custody intact; success records that the copy is retained.
  """
  @spec settle(String.t()) :: {:ok, map() | :waiting} | {:error, term()}
  def settle(action_ref) when is_binary(action_ref) do
    with {:ok, %Action{kind: "quarantine_recovery"} = action} <-
           Repo.fetch(Action.Query.by_action_ref(action_ref)),
         {:ok, command} <-
           Repo.fetch(CoopFleet.Command.Query.by_id(action.outcome["command_id"])) do
      settle_command(action, command)
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :quarantine_action_mismatch}
    end
  end

  def settle(_action_ref), do: {:error, :invalid_quarantine_recovery}

  defp prepare(attributes) do
    session = fetch_and_lock_session!(attributes.session_id)
    placement = verify_local_custody!(session, attributes)
    verify_inspection!(session, placement, attributes)
    enqueue_retirement(session, placement, attributes)
  end

  defp verify_local_custody!(session, attributes) do
    unless supported_owner?(session),
      do: Repo.rollback(:quarantine_owner_unsupported)

    if session.episode_id &&
         Repo.fetch!(Episodes.Episode.Query.by_id(session.episode_id)).state == :working,
       do: Repo.rollback(:quarantine_work_unfinished)

    if session.cleanup_status == :discarded or not is_nil(session.cleanup_lease_ref) or
         session.retained_reason in ["quarantine_recovery_pending", "quarantined_copy"],
       do: Repo.rollback(:quarantine_custody_busy)

    verify_finished!(session)

    # A repository-bearing copy may contain work beyond its last checkpoint.
    # Until its authenticated recovery proof is supplied it cannot be retired.
    unless source_free_or_read_only?(session), do: Repo.rollback(:quarantine_checkpoint_required)
    exact_placement!(session, attributes)
  end

  defp supported_owner?(%Work.Session{execution_kind: :work, episode_id: id})
       when is_binary(id),
       do: true

  # A retired, never-claimed pool session has no request to resume or abandon.
  # Its worker must still prove the exact parked, empty, quarantined copy.
  defp supported_owner?(%Work.Session{
         execution_kind: kind,
         ready_state: :retired,
         episode_id: nil,
         admission_input_id: nil,
         learning_run_id: nil,
         improvement_run_id: nil,
         knowledge_run_id: nil,
         weekly_review_id: nil,
         completion_review_id: nil
       })
       when kind in [:work, :admission],
       do: true

  defp supported_owner?(_session), do: false

  defp exact_placement!(session, attributes) do
    placement =
      Repo.peek(CoopFleet.Placement.Query.by_id(attributes.placement_id)) ||
        Repo.rollback(:quarantine_identity_changed)

    unless session.coop_session_id == attributes.remote_session_id and
             placement.session_id == session.id and
             placement.generation == attributes.placement_generation,
           do: Repo.rollback(:quarantine_identity_changed)

    placement
  end

  defp verify_finished!(session) do
    unfinished = session.id |> Work.Turn.Query.by_session_id() |> Work.Turn.Query.unfinished()
    unsettled = session.id |> Work.Turn.Query.by_session_id() |> Work.Turn.Query.unsettled()

    publication =
      session.id
      |> Publication.Publication.Query.by_session_id()
      |> Publication.Publication.Query.pending()

    commands =
      session.id |> CoopFleet.Command.Query.by_session_id() |> CoopFleet.Command.Query.unsettled()

    if Repo.exists?(unfinished) or Repo.exists?(unsettled) or Repo.exists?(publication) or
         Repo.exists?(commands),
       do: Repo.rollback(:quarantine_work_unfinished)

    :ok
  end

  defp enqueue_retirement(session, placement, attributes) do
    request = %{
      "method" => "POST",
      "path" =>
        "/v1/sessions/" <>
          URI.encode(attributes.remote_session_id, &URI.char_unreserved?/1) <> "/discard",
      "body" => %{
        "retire_quarantined" => true,
        "expected_revision" => attributes.expected_revision
      }
    }

    key = "quarantine:" <> CanonicalJSON.digest(%{"action_ref" => attributes.action_ref})

    with {:ok, command} <-
           CoopFleet.ControlPlane.enqueue_command(placement.id, "api_request", request, key) do
      previous = %{
        "cleanup_status" => Atom.to_string(session.cleanup_status),
        "cleanup_blocked_from" =>
          session.cleanup_blocked_from && Atom.to_string(session.cleanup_blocked_from),
        "cleanup_last_error_code" => session.cleanup_last_error_code,
        "cleanup_last_error_detail" => session.cleanup_last_error_detail,
        "retained_reason" => session.retained_reason,
        "cleanup_next_attempt_at" => UTCDateTime.iso8601(session.cleanup_next_attempt_at),
        "cleanup_receipt" => session.cleanup_receipt,
        "cleanup_receipt_fingerprint" => session.cleanup_receipt_fingerprint
      }

      receipt = %{
        "kind" => "quarantine_recovery_pending",
        "command_id" => command.id,
        "local_session_id" => session.id,
        "remote_session_id" => session.coop_session_id
      }

      persist_retained(session, "quarantine_recovery_pending", receipt)
      {:ok, %{previous: previous, outcome: receipt}}
    end
  end

  defp settle_command(_action, %CoopFleet.Command{status: status})
       when status in [:queued, :delivered, :acknowledged],
       do: {:ok, :waiting}

  defp settle_command(action, %CoopFleet.Command{status: :succeeded} = command) do
    with {:ok, %{"session" => remote}} <- CoopFleet.Bridge.response(command.result),
         true <- remote["id"] == action.outcome["remote_session_id"],
         true <- remote["state"] == "discarded",
         true <- remote["revision"] == command.payload["body"]["expected_revision"] + 1 do
      audit_result(action, command, fn -> complete(action, command, remote) end)
    else
      {:error, {:coop_error, status, code, _detail}}
      when status in 400..499 and code in @refusals ->
        audit_result(action, command, fn -> restore_refused(action, command, code) end)

      _other ->
        {:error, :quarantine_receipt_mismatch}
    end
  end

  defp settle_command(_action, %CoopFleet.Command{}),
    do: {:error, :quarantine_retirement_unconfirmed}

  defp audit_result(action, command, operation) do
    audit = %{
      action: :update,
      action_ref:
        "quarantine-settled:" <> CanonicalJSON.digest(%{"action_ref" => action.action_ref}),
      actor_ref: action.actor_ref,
      kind: "quarantine_recovery_result",
      resource_ref: action.resource_ref,
      request: %{"command_id" => command.id, "result_fingerprint" => command.result_fingerprint}
    }

    Actions.run(audit, operation)
  end

  defp restore_refused(action, command, code) do
    session = fetch_and_lock_session!(action.resource_ref)
    exact_pending!(session, action, command)
    previous = action.previous

    {:ok, cleanup_status} =
      Ecto.Enum.cast_value(Work.Session, :cleanup_status, previous["cleanup_status"])

    {:ok, blocked_from} =
      Ecto.Enum.cast_value(Work.Session, :cleanup_blocked_from, previous["cleanup_blocked_from"])

    next_at =
      case UTCDateTime.parse(previous["cleanup_next_attempt_at"]) do
        {:ok, at} -> at
        :error -> nil
      end

    Retention.Custody.persist(session, %{
      cleanup_status: cleanup_status,
      cleanup_blocked_from: blocked_from,
      cleanup_last_error_code: previous["cleanup_last_error_code"],
      cleanup_last_error_detail: previous["cleanup_last_error_detail"],
      cleanup_next_attempt_at: next_at,
      retained_reason: previous["retained_reason"],
      cleanup_receipt: previous["cleanup_receipt"],
      cleanup_receipt_fingerprint: previous["cleanup_receipt_fingerprint"]
    })

    {:ok,
     %{
       previous: action.outcome,
       outcome: %{"kind" => "quarantine_retirement_refused", "code" => code}
     }}
  end

  defp complete(action, command, remote) do
    session = fetch_and_lock_session!(action.resource_ref)

    exact_pending!(session, action, command)

    unless CoopFleet.JobAuthority.exact_cleanup_receipt(session, remote) == :ok,
      do: Repo.rollback(:quarantine_receipt_mismatch)

    receipt = %{
      "kind" => "quarantined_copy_retained",
      "command_id" => command.id,
      "operation_key" => command.idempotency_key,
      "local_session_id" => session.id,
      "remote_session_id" => session.coop_session_id,
      "remote_state" => "discarded"
    }

    :ok = CoopFleet.ControlPlane.retire_session_placements(session.id, Repo.now!())
    persist_retained(session, "quarantined_copy", receipt)
    {:ok, %{previous: action.outcome, outcome: receipt}}
  end

  defp exact_pending!(session, action, command) do
    unless session.retained_reason == "quarantine_recovery_pending" and
             session.cleanup_receipt == action.outcome and command.session_id == session.id,
           do: Repo.rollback(:quarantine_identity_changed)
  end

  defp persist_retained(session, reason, receipt) do
    Retention.Custody.persist(session, %{
      cleanup_status: :retained,
      cleanup_blocked_from: nil,
      cleanup_last_error_code: nil,
      cleanup_last_error_detail: nil,
      retained_reason: reason,
      cleanup_next_attempt_at: nil,
      cleanup_receipt: receipt,
      cleanup_receipt_fingerprint: CanonicalJSON.digest(receipt)
    })
  end

  defp fetch_and_lock_session!(id) do
    CoopFleet.ControlPlane.lock_holding_workers(id)

    session =
      Repo.peek(Work.Session.Query.by_id(id)) || Repo.rollback(:quarantine_session_missing)

    if session.episode_id do
      locked =
        session.episode_id
        |> Episodes.Episode.Query.by_id()
        |> Episodes.Episode.Query.lock_next_free()
        |> Repo.peek()

      unless locked, do: Repo.rollback(:quarantine_custody_busy)
    end

    id |> Work.Session.Query.by_id() |> Work.Session.Query.lock_next_free() |> Repo.peek() ||
      Repo.rollback(:quarantine_custody_busy)
  end

  defp source_free_or_read_only?(%Work.Session{repository_ref: nil, worker_job_document: nil}),
    do: true

  defp source_free_or_read_only?(
         %Work.Session{
           worker_job_document: %{"repository_read_only" => true}
         } = session
       ),
       do: match?({:ok, _}, CoopFleet.JobAuthority.validate(session))

  defp source_free_or_read_only?(_session), do: false

  defp verify_inspection!(session, placement, attributes) do
    inspection = Repo.peek(CoopFleet.Command.Query.by_id(attributes.inspection_command_id))
    path = "/v1/sessions/" <> URI.encode(session.coop_session_id, &URI.char_unreserved?/1)

    valid =
      with %CoopFleet.Command{status: :succeeded, kind: "api_request"} <- inspection,
           true <-
             inspection.session_id == session.id and inspection.placement_id == placement.id and
               inspection.placement_generation == placement.generation,
           %{"method" => "GET", "path" => ^path} <- inspection.payload,
           {:ok, %{} = remote} <- CoopFleet.Bridge.response(inspection.result),
           true <-
             remote["id"] == session.coop_session_id and
               remote["revision"] == attributes.expected_revision,
           true <-
             remote["state"] in ["open", "closed"] and remote["activity"] == "parked" and
               remote["active_turn_id"] in [nil, ""] and remote["queued_turn_count"] == 0 and
               remote["queued_prompt_bytes"] == 0,
           :ok <- CoopFleet.JobAuthority.exact_cleanup_receipt(session, remote) do
        true
      else
        _mismatch -> false
      end

    unless valid, do: Repo.rollback(:quarantine_inspection_mismatch)
  end

  defp validate(attributes) do
    valid =
      Maps.exact_keys?(attributes, @fields) and
        Enum.all?(
          [:session_id, :placement_id, :inspection_command_id],
          &match?({:ok, _}, Ecto.UUID.cast(attributes[&1]))
        ) and
        Enum.all?(
          [:expected_revision, :placement_generation],
          &(is_integer(attributes[&1]) and attributes[&1] > 0)
        ) and
        Reference.valid?(attributes.remote_session_id)

    if valid, do: :ok, else: {:error, :invalid_quarantine_recovery}
  end
end
