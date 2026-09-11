defmodule Responder.Slack.InteractionAudits do
  @moduledoc """
  Durable audit and repaint custody for Slack controls and typed question answers.

  The Socket Mode envelope is acknowledged only after this ledger records the
  authority outcome. Denials need no shared-message mutation. Stale and confirmed controls
  enter a fenced repaint queue so the host-owned message catches up even when
  the gateway process exits immediately after acknowledging the user.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.State.Record
  alias Responder.Work.Turn

  alias Responder.Slack.{Interaction, InteractionAudit, InteractionAuditChangeset}

  @maximum_error_detail_bytes 4_096
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
        %Entry{source_kind: "slack", actor_kind: :user} = entry,
        %Record{} = record,
        %Turn{external_receipt: receipt},
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

  @spec defer(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), term()) ::
          {:ok, InteractionAudit.t()} | {:error, term()}
  def defer(id, lease_ref, retry_seconds, reason)
      when is_integer(retry_seconds) and retry_seconds > 0 do
    mutate_claim(id, lease_ref, fn audit, now ->
      {code, detail} = describe_error(reason)

      update!(audit, %{
        last_error_code: code,
        last_error_detail: detail,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: DateTime.add(now, retry_seconds, :second)
      })
    end)
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
      Repo.one(
        from(audit in InteractionAudit,
          where: audit.event_ref == ^attributes.event_ref,
          lock: "FOR UPDATE"
        )
      )

    case existing do
      %InteractionAudit{} = audit ->
        # occurred_at is the gateway's receive time, not Slack event identity.
        # A redelivered envelope keeps the first receipt and its repaint lease.
        if Map.take(audit, @identity_fields) == Map.take(attributes, @identity_fields),
          do: %{audit: audit, status: :duplicate},
          else: Repo.rollback(:slack_interaction_event_conflict)

      nil ->
        case attributes |> InteractionAuditChangeset.insert() |> Repo.insert() do
          {:ok, audit} ->
            %{audit: audit, status: :recorded}

          {:error, changeset} ->
            Repo.rollback({:slack_interaction_audit_persistence_failed, changeset.errors})
        end
    end
  end

  defp rearm_locked(event_ref) do
    case Repo.one(
           from(audit in InteractionAudit,
             where: audit.event_ref == ^event_ref,
             lock: "FOR UPDATE"
           )
         ) do
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
    now = database_now!()

    query =
      from(audit in InteractionAudit,
        where:
          audit.repaint_status == :pending and
            (is_nil(audit.next_attempt_at) or audit.next_attempt_at <= ^now) and
            (is_nil(audit.lease_expires_at) or audit.lease_expires_at <= ^now),
        order_by: [asc: audit.occurred_at, asc: audit.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    case Repo.one(query) do
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
    now = database_now!()

    case Repo.one(from(audit in InteractionAudit, where: audit.id == ^id, lock: "FOR UPDATE")) do
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
      id: Ecto.UUID.generate(),
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
    case audit |> InteractionAuditChangeset.update(attributes) |> Repo.update() do
      {:ok, updated} ->
        updated

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

    detail =
      reason
      |> inspect(limit: 30, printable_limit: 3_000)
      |> byte_slice(@maximum_error_detail_bytes)

    {code, detail}
  end

  defp digest(value),
    do: value |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

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

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp reference(value, field, maximum) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= maximum,
       do: :ok,
       else: {:error, {:invalid_slack_interaction_audit, field}}
  end

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
end
