defmodule Ryker.Slack.InteractionAudits do
  @moduledoc """
  Durable audit and repaint custody for Slack controls and typed question answers.

  The Socket Mode envelope is acknowledged only after this ledger records the
  authority outcome. Denials need no shared-message mutation. Stale and confirmed controls
  enter a fenced repaint queue so the host-owned message catches up even when
  the gateway process exits immediately after acknowledging the user.

  Each control recorded, repainted, deferred, blocked or rearmed is announced
  after the outermost commit (`subscribe_interactions/0`).
  """
  alias Ryker.CanonicalJSON
  alias Ryker.Crypto
  alias Ryker.ErrorDetail
  alias Ryker.Ingress
  alias Ryker.Records
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Slack.{Interaction, InteractionAudit}
  alias Ryker.UTCDateTime
  alias Ryker.Work

  @identity_fields ~w(action_id action_value_digest actor_ref channel_ref event_ref message_ref outcome thread_ref workspace_ref)a

  @spec record(Interaction.t(), :denied | :invalid | :confirmed) ::
          {:ok, %{audit: InteractionAudit.t(), status: :recorded | :duplicate}}
          | {:error, term()}
  def record(%Interaction{} = interaction, outcome)
      when outcome in [:denied, :invalid, :confirmed] do
    attributes = attributes(interaction, outcome)

    Repo.transaction(fn -> record_locked(attributes) end)
    |> transaction_result()
  end

  def record(_interaction, _outcome),
    do: {:error, {:invalid_slack_interaction_audit, :request}}

  @doc false
  def record_answer_in_transaction(
        %Ingress.Inbox.Entry{source_kind: "slack", actor_kind: :user} = entry,
        %Records.Record{} = record,
        %Work.Turn{external_receipt: receipt},
        kind
      )
      when kind in [:typed, :choice] do
    # InputRequests has already checked this delivered question and source. Keep
    # the real answer identity and distinguish typed replies from native choices.
    if Repo.in_transaction?() do
      ["slack", workspace, channel] =
        String.split(entry.destination_conversation_ref, ":", parts: 3)

      %{
        action_id: "#{kind}_question_answer",
        action_value: record.ref,
        actor_ref: entry.actor_ref,
        channel_ref: channel,
        event_ref: entry.event_ref,
        message_ref: receipt["message_ref"],
        occurred_at: entry.occurred_at,
        thread_ref: entry.destination_thread_ref,
        workspace_ref: workspace
      }
      |> attributes(:confirmed)
      |> record_locked()

      :ok
    else
      {:error, :state_record_transaction_required}
    end
  end

  def record_answer_in_transaction(_entry, _record, _turn, _kind), do: :ok

  @doc """
  The earliest moment after `since` at which a pending repaint becomes
  claimable by the clock alone: its retry's backoff ends, or the lease of a
  claim nobody renewed runs out. Nil when no repaint waits on the clock.
  """
  @spec next_due_at(DateTime.t()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since) do
    since
    |> InteractionAudit.Query.select_next_due_after()
    |> Repo.one()
    |> UTCDateTime.earliest()
  end

  @spec claim_next(String.t(), pos_integer()) ::
          {:ok, InteractionAudit.t() | nil} | {:error, term()}
  def claim_next(worker_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref, 1_024),
         :ok <- integer(lease_seconds, 5..3_600, :lease_seconds) do
      Repo.transaction(fn -> claim_next_locked(worker_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  @spec settle(Ecto.UUID.t(), Ecto.UUID.t()) ::
          {:ok, InteractionAudit.t()} | {:error, term()}
  def settle(id, lease_ref) do
    mutate_claim(id, lease_ref, fn audit, now ->
      update!(audit, %{
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        repaint_status: :settled,
        repainted_at: now
      })
    end)
  end

  @doc """
  Repaints again after `retry_seconds`. With `counted: false` the attempt just
  made is given back, for a wait Slack asked for rather than a failure.
  """
  @spec defer(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), term(), keyword()) ::
          {:ok, InteractionAudit.t()} | {:error, term()}
  def defer(id, lease_ref, retry_seconds, reason, options \\ [])
      when is_integer(retry_seconds) and retry_seconds > 0 do
    mutate_claim(id, lease_ref, fn audit, now ->
      {code, detail} = describe_error(reason)

      update!(audit, %{
        attempt_count: given_back(audit.attempt_count, options),
        last_error_code: code,
        last_error_detail: detail,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: DateTime.add(now, retry_seconds, :second)
      })
    end)
  end

  defp given_back(attempt_count, options) do
    if Keyword.get(options, :counted, true), do: attempt_count, else: max(attempt_count - 1, 0)
  end

  @spec block(Ecto.UUID.t(), Ecto.UUID.t(), term()) ::
          {:ok, InteractionAudit.t()} | {:error, term()}
  def block(id, lease_ref, reason) do
    mutate_claim(id, lease_ref, fn audit, _now ->
      {code, detail} = describe_error(reason)

      update!(audit, %{
        last_error_code: code,
        last_error_detail: detail,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        repaint_status: :blocked
      })
    end)
  end

  @doc """
  Rearms one exact blocked stale-control repaint after operator inspection.

  The immutable audit target remains unchanged; only retry custody is reset.
  """
  @spec rearm(String.t()) :: {:ok, InteractionAudit.t()} | {:error, term()}
  def rearm(event_ref) do
    with :ok <- reference(event_ref, :event_ref, 1_024) do
      Repo.transaction(fn -> rearm_locked(event_ref) end)
      |> transaction_result()
    end
  end

  defp record_locked(attributes) do
    existing =
      attributes.event_ref
      |> InteractionAudit.Query.by_event_ref()
      |> InteractionAudit.Query.lock_for_update()
      |> Repo.one()

    case existing do
      %InteractionAudit{} = audit ->
        # occurred_at is the gateway's receive time, not Slack event identity.
        # A redelivered envelope keeps the first receipt and its repaint lease.
        if Map.take(audit, @identity_fields) == Map.take(attributes, @identity_fields),
          do: %{audit: audit, status: :duplicate},
          else: Repo.rollback(:slack_interaction_event_conflict)

      nil ->
        changeset = InteractionAudit.Changeset.insert(attributes)

        case Repo.insert(changeset) do
          {:ok, audit} ->
            broadcast_interaction_updated(audit)
            %{audit: audit, status: :recorded}

          {:error, changeset} ->
            Repo.rollback({:slack_interaction_audit_persistence_failed, changeset.errors})
        end
    end
  end

  defp rearm_locked(event_ref) do
    locked =
      event_ref
      |> InteractionAudit.Query.by_event_ref()
      |> InteractionAudit.Query.lock_for_update()
      |> Repo.one()

    case locked do
      nil ->
        Repo.rollback(:slack_interaction_audit_not_found)

      %InteractionAudit{repaint_status: :blocked} = audit ->
        update!(audit, %{
          attempt_count: 0,
          last_error_code: nil,
          last_error_detail: nil,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: nil,
          repaint_status: :pending,
          repainted_at: nil
        })

      %InteractionAudit{} ->
        Repo.rollback(:slack_interaction_audit_not_blocked)
    end
  end

  defp claim_next_locked(worker_ref, lease_seconds) do
    now = Repo.now!()

    next = now |> InteractionAudit.Query.next_claimable() |> Repo.one()

    case next do
      nil ->
        nil

      %InteractionAudit{} = audit ->
        update!(audit, %{
          attempt_count: audit.attempt_count + 1,
          lease_expires_at: DateTime.add(now, lease_seconds, :second),
          lease_owner: worker_ref,
          lease_ref: Ecto.UUID.generate(),
          next_attempt_at: nil
        })
    end
  end

  defp mutate_claim(id, lease_ref, callback) do
    with {:ok, id} <- uuid(id, :id),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref) do
      Repo.transaction(fn -> mutate_claim_locked(id, lease_ref, callback) end)
      |> transaction_result()
    end
  end

  defp mutate_claim_locked(id, lease_ref, callback) do
    now = Repo.now!()

    locked =
      id
      |> InteractionAudit.Query.by_id()
      |> InteractionAudit.Query.lock_for_update()
      |> Repo.one()

    case locked do
      nil ->
        Repo.rollback(:slack_interaction_audit_not_found)

      %InteractionAudit{lease_ref: ^lease_ref, lease_expires_at: expires_at} = audit ->
        mutate_live_claim(audit, expires_at, now, callback)

      %InteractionAudit{} ->
        Repo.rollback(:slack_interaction_audit_lease_lost)
    end
  end

  defp mutate_live_claim(audit, expires_at, now, callback) do
    if DateTime.compare(expires_at, now) == :gt,
      do: callback.(audit, now),
      else: Repo.rollback(:slack_interaction_audit_lease_lost)
  end

  defp attributes(interaction, outcome) do
    document = %{
      "action_id" => interaction.action_id,
      "action_value" => interaction.action_value,
      "actor_ref" => interaction.actor_ref,
      "channel_ref" => interaction.channel_ref,
      "event_ref" => interaction.event_ref,
      "message_ref" => interaction.message_ref,
      "occurred_at" => DateTime.to_iso8601(interaction.occurred_at),
      "outcome" => Atom.to_string(outcome),
      "thread_ref" => interaction.thread_ref,
      "workspace_ref" => interaction.workspace_ref
    }

    %{
      action_id: interaction.action_id,
      action_value_digest: digest(interaction.action_value),
      actor_ref: interaction.actor_ref,
      attempt_count: 0,
      channel_ref: interaction.channel_ref,
      event_ref: interaction.event_ref,
      id: Repo.generate_id(),
      message_ref: interaction.message_ref,
      occurred_at: interaction.occurred_at,
      outcome: outcome,
      repaint_status: if(outcome == :denied, do: :none, else: :pending),
      request_fingerprint: CanonicalJSON.digest(document),
      thread_ref: interaction.thread_ref,
      workspace_ref: interaction.workspace_ref
    }
  end

  defp update!(audit, attributes) do
    changeset = InteractionAudit.Changeset.update(audit, attributes)

    case Repo.update(changeset) do
      {:ok, updated} ->
        tap(updated, &broadcast_interaction_updated/1)

      {:error, changeset} ->
        Repo.rollback({:slack_interaction_audit_persistence_failed, changeset.errors})
    end
  end

  defp describe_error(reason) do
    code =
      reason
      |> case do
        value when is_atom(value) -> Atom.to_string(value)
        {value, _detail} when is_atom(value) -> Atom.to_string(value)
        _other -> "slack_interaction_repaint_error"
      end
      |> byte_slice(120)

    {code, ErrorDetail.detail(reason)}
  end

  defp digest(value),
    do: value |> Crypto.sha256_hex()

  defp byte_slice(value, maximum) do
    if byte_size(value) <= maximum,
      do: value,
      else: value |> String.graphemes() |> take_bytes(maximum, "")
  end

  defp take_bytes([], _maximum, output), do: output

  defp take_bytes([grapheme | rest], maximum, output) do
    if byte_size(output) + byte_size(grapheme) <= maximum,
      do: take_bytes(rest, maximum, output <> grapheme),
      else: output
  end

  defp reference(value, field, maximum),
    do: Reference.check(value, field, :invalid_slack_interaction_audit, maximum)

  defp integer(value, range, field) do
    if is_integer(value) and value in range,
      do: :ok,
      else: {:error, {:invalid_slack_interaction_audit, field}}
  end

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_slack_interaction_audit, field}}
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to Slack control changes:
  `{:slack_interaction_updated, audit_id}` once someone's click or answer in
  Slack is recorded, or the message it changed is repainted, deferred,
  blocked or rearmed, and that change has committed.
  """
  def subscribe_interactions, do: Ryker.PubSub.subscribe(interactions_topic())

  def unsubscribe_interactions, do: Ryker.PubSub.unsubscribe(interactions_topic())

  defp interactions_topic, do: "slack:interactions"

  defp broadcast_interaction_updated(%InteractionAudit{id: id}) do
    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(interactions_topic(), {:slack_interaction_updated, id})
    end)
  end
end
