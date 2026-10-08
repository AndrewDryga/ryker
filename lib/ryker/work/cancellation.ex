defmodule Ryker.Work.Cancellation do
  @moduledoc """
  Canonical intent and proof for stopping one bound Coop turn.

  The intent is persisted before the remote mutation. Its exact operation key
  can then be reconciled after a lost response or worker restart. Only a
  terminal remote turn proof, or the removal from Ryker of the worker holding
  the run, permits the episode kernel to cancel or transfer ownership.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Maps
  alias Ryker.Reference

  @intent_fields ~w(action cancel_ref new_turn_ref reason required_input_ref transfer_ref)
  @absent_receipt_fields ~w(close_operation_ref create_operation_ref kind remote_session_id session_state submit_operation_ref)
  @terminal_receipt_fields ~w(cancel_operation_ref close_operation_ref kind remote_session_id remote_state remote_turn_id session_state)
  @removed_receipt_fields ~w(kind remote_session_id remote_turn_id worker_id)
  @terminal_states ~w(cancelled completed failed interrupted budget_exhausted)
  @session_states ~w(open exhausted closed discarded)
  # A stop retries on its own for as long as it takes, because only the
  # worker's answer (or its removal) proves a run stopped. After this many
  # attempts, about two minutes of backoff, it is listed on Failures with
  # what would let it finish.
  @stalled_after_attempts 8

  @type intent :: map()
  @type receipt :: map()

  @doc "How many failed attempts make a pending stop worth a person's attention."
  @spec stalled_after_attempts() :: pos_integer()
  def stalled_after_attempts, do: @stalled_after_attempts

  @spec new_cancel(String.t(), String.t()) :: {:ok, intent()} | {:error, term()}
  def new_cancel(cancel_ref, reason) do
    intent = %{
      "action" => "cancel",
      "cancel_ref" => cancel_ref,
      "new_turn_ref" => nil,
      "reason" => reason,
      "required_input_ref" => nil,
      "transfer_ref" => nil
    }

    prepare(intent)
  end

  @spec new_transfer(String.t(), String.t(), String.t() | nil) ::
          {:ok, intent()} | {:error, term()}
  def new_transfer(new_turn_ref, transfer_ref, required_input_ref \\ nil) do
    intent = %{
      "action" => "transfer",
      "cancel_ref" => nil,
      "new_turn_ref" => new_turn_ref,
      "reason" => nil,
      "required_input_ref" => required_input_ref,
      "transfer_ref" => transfer_ref
    }

    prepare(intent)
  end

  @spec new_block(String.t()) :: {:ok, intent()} | {:error, term()}
  def new_block(reason) do
    intent = %{
      "action" => "block",
      "cancel_ref" => nil,
      "new_turn_ref" => nil,
      "reason" => reason,
      "required_input_ref" => nil,
      "transfer_ref" => nil
    }

    prepare(intent)
  end

  @doc """
  A person's Stop: a block, so the task waits for a reply, that names the
  control which stopped it as its `cancel_ref`. A block Ryker requests names
  none, so a stop is told apart by what it is, not by its words: the
  Failures page read it from one sentence, and a Stop pressed in Chat, worded
  its own way, was listed as a task that stopped for no known reason.
  """
  @spec new_stop(String.t(), String.t()) :: {:ok, intent()} | {:error, term()}
  def new_stop(stop_ref, reason) do
    intent = %{
      "action" => "block",
      "cancel_ref" => stop_ref,
      "new_turn_ref" => nil,
      "reason" => reason,
      "required_input_ref" => nil,
      "transfer_ref" => nil
    }

    prepare(intent)
  end

  @spec prepare(term()) :: {:ok, intent()} | {:error, term()}
  def prepare(%{} = intent) do
    if Maps.exact_keys?(intent, @intent_fields) do
      prepare_shape(intent)
    else
      {:error, {:invalid_work_cancellation, :fields}}
    end
  end

  def prepare(_intent), do: {:error, {:invalid_work_cancellation, :document}}

  @spec fingerprint(intent() | receipt()) :: String.t()
  def fingerprint(document), do: CanonicalJSON.digest(document)

  @spec terminal_receipt(
          String.t(),
          String.t(),
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | nil
        ) ::
          {:ok, receipt()} | {:error, term()}
  def terminal_receipt(
        remote_session_id,
        remote_turn_id,
        remote_state,
        cancel_operation_ref,
        session_state,
        close_operation_ref
      ) do
    receipt = %{
      "cancel_operation_ref" => cancel_operation_ref,
      "close_operation_ref" => close_operation_ref,
      "kind" => "terminal_turn",
      "remote_session_id" => remote_session_id,
      "remote_state" => remote_state,
      "remote_turn_id" => remote_turn_id,
      "session_state" => session_state
    }

    if Reference.valid?(remote_session_id) and Reference.valid?(remote_turn_id) and
         remote_state in @terminal_states and optional_reference?(cancel_operation_ref) and
         session_state in @session_states and optional_reference?(close_operation_ref),
       do: {:ok, receipt},
       else: {:error, {:invalid_work_cancellation, :receipt}}
  end

  @spec absent_receipt(
          String.t(),
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) ::
          {:ok, receipt()} | {:error, term()}
  def absent_receipt(
        create_operation_ref,
        submit_operation_ref,
        remote_session_id,
        session_state,
        close_operation_ref
      ) do
    receipt = %{
      "close_operation_ref" => close_operation_ref,
      "create_operation_ref" => create_operation_ref,
      "kind" => "absent_turn",
      "remote_session_id" => remote_session_id,
      "session_state" => session_state,
      "submit_operation_ref" => submit_operation_ref
    }

    if Reference.valid?(create_operation_ref) and optional_reference?(submit_operation_ref) and
         optional_session?(remote_session_id, session_state, close_operation_ref),
       do: {:ok, receipt},
       else: {:error, {:invalid_work_cancellation, :receipt}}
  end

  @doc """
  Proof that a run stopped because the worker holding it was removed.

  Removal revokes the worker's certificates and placements for good, and the
  run's state tools with the placement: nothing the run still does can reach
  Ryker, so the stop needs no answer from it. Custody checks the removal
  itself before it accepts this receipt.
  """
  @spec worker_removed_receipt(String.t() | nil, String.t() | nil, String.t()) ::
          {:ok, receipt()} | {:error, term()}
  def worker_removed_receipt(remote_session_id, remote_turn_id, worker_id) do
    receipt = %{
      "kind" => "worker_removed",
      "remote_session_id" => remote_session_id,
      "remote_turn_id" => remote_turn_id,
      "worker_id" => worker_id
    }

    if optional_reference?(remote_session_id) and optional_reference?(remote_turn_id) and
         (is_nil(remote_turn_id) or is_binary(remote_session_id)) and Reference.valid?(worker_id),
       do: {:ok, receipt},
       else: {:error, {:invalid_work_cancellation, :receipt}}
  end

  @spec prepare_receipt(term()) :: {:ok, receipt()} | {:error, term()}
  def prepare_receipt(%{"kind" => "worker_removed"} = receipt) do
    if Maps.exact_keys?(receipt, @removed_receipt_fields) do
      worker_removed_receipt(
        receipt["remote_session_id"],
        receipt["remote_turn_id"],
        receipt["worker_id"]
      )
    else
      {:error, {:invalid_work_cancellation, :receipt}}
    end
  end

  def prepare_receipt(%{"kind" => "terminal_turn"} = receipt) do
    if Maps.exact_keys?(receipt, @terminal_receipt_fields) do
      terminal_receipt(
        receipt["remote_session_id"],
        receipt["remote_turn_id"],
        receipt["remote_state"],
        receipt["cancel_operation_ref"],
        receipt["session_state"],
        receipt["close_operation_ref"]
      )
    else
      {:error, {:invalid_work_cancellation, :receipt}}
    end
  end

  def prepare_receipt(%{"kind" => "absent_turn"} = receipt) do
    if Maps.exact_keys?(receipt, @absent_receipt_fields) do
      absent_receipt(
        receipt["create_operation_ref"],
        receipt["submit_operation_ref"],
        receipt["remote_session_id"],
        receipt["session_state"],
        receipt["close_operation_ref"]
      )
    else
      {:error, {:invalid_work_cancellation, :receipt}}
    end
  end

  def prepare_receipt(_receipt), do: {:error, {:invalid_work_cancellation, :receipt}}

  @spec command(intent(), map(), DateTime.t()) :: Episodes.Command.t()
  def command(
        %{
          "action" => "cancel",
          "cancel_ref" => cancel_ref,
          "reason" => reason
        },
        episode,
        occurred_at
      ) do
    %Episodes.Command.CancelEpisode{
      cancel_ref: cancel_ref,
      episode_key: episode.key,
      expected_owner: %{kind: :turn, ref: episode.owner_ref},
      occurred_at: occurred_at,
      reason: reason
    }
  end

  def command(%{"action" => "block"}, _episode, _occurred_at), do: nil

  def command(
        %{
          "action" => "transfer",
          "new_turn_ref" => new_turn_ref,
          "required_input_ref" => required_input_ref,
          "transfer_ref" => transfer_ref
        },
        episode,
        occurred_at
      ) do
    %Episodes.Command.TransferOwner{
      episode_key: episode.key,
      expected_owner: %{kind: :turn, ref: episode.owner_ref},
      new_owner: %{kind: :turn, ref: new_turn_ref},
      occurred_at: occurred_at,
      required_input_ref: required_input_ref,
      transfer_ref: transfer_ref
    }
  end

  defp prepare_shape(
         %{
           "action" => "cancel",
           "cancel_ref" => cancel_ref,
           "new_turn_ref" => nil,
           "reason" => reason,
           "required_input_ref" => nil,
           "transfer_ref" => nil
         } = intent
       ) do
    if Reference.valid?(cancel_ref) and Reference.valid?(reason, 512),
      do: {:ok, intent},
      else: {:error, {:invalid_work_cancellation, :cancel}}
  end

  defp prepare_shape(
         %{
           "action" => "block",
           "cancel_ref" => stop_ref,
           "new_turn_ref" => nil,
           "reason" => reason,
           "required_input_ref" => nil,
           "transfer_ref" => nil
         } = intent
       ) do
    if optional_reference?(stop_ref) and Reference.valid?(reason, 4_096),
      do: {:ok, intent},
      else: {:error, {:invalid_work_cancellation, :block}}
  end

  defp prepare_shape(
         %{
           "action" => "transfer",
           "cancel_ref" => nil,
           "new_turn_ref" => new_turn_ref,
           "reason" => nil,
           "required_input_ref" => required_input_ref,
           "transfer_ref" => transfer_ref
         } = intent
       ) do
    if Reference.valid?(new_turn_ref) and optional_reference?(required_input_ref) and
         Reference.valid?(transfer_ref),
       do: {:ok, intent},
       else: {:error, {:invalid_work_cancellation, :transfer}}
  end

  defp prepare_shape(_intent), do: {:error, {:invalid_work_cancellation, :shape}}

  defp optional_reference?(nil), do: true
  defp optional_reference?(value), do: Reference.valid?(value)

  defp optional_session?(nil, nil, nil), do: true

  defp optional_session?(remote_session_id, session_state, close_operation_ref) do
    Reference.valid?(remote_session_id) and session_state in @session_states and
      optional_reference?(close_operation_ref)
  end
end
