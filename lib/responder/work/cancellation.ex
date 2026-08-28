defmodule Responder.Work.Cancellation do
  @moduledoc """
  Canonical intent and proof for stopping one bound Coop turn.

  The intent is persisted before the remote mutation. Its exact operation key
  can then be reconciled after a lost response or worker restart. Only a
  terminal remote turn proof permits the episode kernel to cancel or transfer
  ownership.
  """

  alias Responder.CanonicalJSON
  alias Responder.Episodes.Command

  @intent_fields ~w(action cancel_ref new_turn_ref reason required_input_ref transfer_ref)
  @absent_receipt_fields ~w(close_operation_ref create_operation_ref kind remote_session_id session_state submit_operation_ref)
  @terminal_receipt_fields ~w(cancel_operation_ref close_operation_ref kind remote_session_id remote_state remote_turn_id session_state)
  @terminal_states ~w(cancelled completed failed interrupted budget_exhausted)
  @session_states ~w(open exhausted closed discarded)

  @type intent :: map()
  @type receipt :: map()

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

  @spec prepare(term()) :: {:ok, intent()} | {:error, term()}
  def prepare(%{} = intent) do
    if Map.keys(intent) |> Enum.sort() == @intent_fields do
      prepare_shape(intent)
    else
      {:error, {:invalid_work_cancellation, :fields}}
    end
  end

  def prepare(_intent), do: {:error, {:invalid_work_cancellation, :document}}

  @spec fingerprint(intent() | receipt()) :: String.t()
  def fingerprint(document), do: CanonicalJSON.digest(document)

  @spec operation_key(Ecto.UUID.t(), pos_integer()) :: String.t()
  def operation_key(turn_id, generation),
    do: "responder:work:cancel:#{turn_id}:g#{generation}"

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

    if reference?(remote_session_id) and reference?(remote_turn_id) and
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

    if reference?(create_operation_ref) and optional_reference?(submit_operation_ref) and
         optional_session?(remote_session_id, session_state, close_operation_ref),
       do: {:ok, receipt},
       else: {:error, {:invalid_work_cancellation, :receipt}}
  end

  @spec prepare_receipt(term()) :: {:ok, receipt()} | {:error, term()}
  def prepare_receipt(%{"kind" => "terminal_turn"} = receipt) do
    if Map.keys(receipt) |> Enum.sort() == @terminal_receipt_fields do
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
    if Map.keys(receipt) |> Enum.sort() == @absent_receipt_fields do
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

  @spec command(intent(), map(), DateTime.t()) :: Command.t()
  def command(
        %{
          "action" => "cancel",
          "cancel_ref" => cancel_ref,
          "reason" => reason
        },
        episode,
        occurred_at
      ) do
    %Command.CancelEpisode{
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
    %Command.TransferOwner{
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
    if reference?(cancel_ref) and bounded_text?(reason, 512),
      do: {:ok, intent},
      else: {:error, {:invalid_work_cancellation, :cancel}}
  end

  defp prepare_shape(
         %{
           "action" => "block",
           "cancel_ref" => nil,
           "new_turn_ref" => nil,
           "reason" => reason,
           "required_input_ref" => nil,
           "transfer_ref" => nil
         } = intent
       ) do
    if bounded_text?(reason, 4_096),
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
    if reference?(new_turn_ref) and optional_reference?(required_input_ref) and
         reference?(transfer_ref),
       do: {:ok, intent},
       else: {:error, {:invalid_work_cancellation, :transfer}}
  end

  defp prepare_shape(_intent), do: {:error, {:invalid_work_cancellation, :shape}}

  defp reference?(value), do: bounded_text?(value, 1_024)
  defp optional_reference?(nil), do: true
  defp optional_reference?(value), do: reference?(value)

  defp optional_session?(nil, nil, nil), do: true

  defp optional_session?(remote_session_id, session_state, close_operation_ref) do
    reference?(remote_session_id) and session_state in @session_states and
      optional_reference?(close_operation_ref)
  end

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end
end
