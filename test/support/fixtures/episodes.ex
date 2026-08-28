defmodule Responder.Fixtures.Episodes do
  @moduledoc false
  alias Responder.Episodes.Command

  @occurred_at ~U[2026-08-27 12:00:00.000000Z]

  def admit_input(overrides \\ %{}) do
    defaults = %{
      actor_ref: "slack:user:U1",
      destination: %{
        conversation_ref: "C-alerts",
        thread_ref: "1787832000.000100",
        transport: "slack"
      },
      episode_id: "01993d45-d400-7000-8000-000000000001",
      episode_key: "grafana:rule-1:fingerprint-1:cycle-1",
      linked_episode_id: nil,
      native_input_id: "slack:event:Ev1",
      occurred_at: @occurred_at,
      payload: %{"status" => "firing"},
      revision: 1,
      turn_ref: "turn-1"
    }

    struct!(Command.AdmitInput, Map.merge(defaults, overrides))
  end

  def transfer_owner(overrides \\ %{}) do
    defaults = %{
      episode_key: "grafana:rule-1:fingerprint-1:cycle-1",
      expected_owner: %{kind: :turn, ref: "turn-1"},
      new_owner: %{kind: :turn, ref: "turn-1-replacement"},
      occurred_at: DateTime.add(@occurred_at, 1, :second),
      transfer_ref: "owner-transfer-1"
    }

    struct!(Command.TransferOwner, Map.merge(defaults, overrides))
  end

  def start_wait(overrides \\ %{}) do
    defaults = %{
      deadline_at: nil,
      episode_key: "grafana:rule-1:fingerprint-1:cycle-1",
      expected_turn_ref: "turn-1",
      kind: :input,
      occurred_at: DateTime.add(@occurred_at, 1, :second),
      wait_ref: "question-1"
    }

    struct!(Command.StartWait, Map.merge(defaults, overrides))
  end

  def resume_wait(overrides \\ %{}) do
    defaults = %{
      episode_key: "grafana:rule-1:fingerprint-1:cycle-1",
      expected_wait: %{kind: :input, ref: "question-1"},
      occurred_at: DateTime.add(@occurred_at, 3, :second),
      resolution_ref:
        Command.dedupe_key(admit_input(%{native_input_id: "slack:event:Ev-answer"})),
      turn_ref: "turn-2"
    }

    struct!(Command.ResumeWait, Map.merge(defaults, overrides))
  end

  def accept_result(overrides \\ %{}) do
    defaults = %{
      delivery: :reply,
      decision_reason: nil,
      delivery_ref: "slack-delivery-1",
      episode_key: "grafana:rule-1:fingerprint-1:cycle-1",
      expected_turn_ref: "turn-1",
      next_turn_ref: nil,
      occurred_at: DateTime.add(@occurred_at, 1, :second),
      result_ref: "result-1"
    }

    struct!(Command.AcceptResult, Map.merge(defaults, overrides))
  end

  def confirm_delivery(overrides \\ %{}) do
    defaults = %{
      episode_key: "grafana:rule-1:fingerprint-1:cycle-1",
      expected_delivery_ref: "slack-delivery-1",
      next_turn_ref: nil,
      next_wait: nil,
      occurred_at: DateTime.add(@occurred_at, 2, :second)
    }

    struct!(Command.ConfirmDelivery, Map.merge(defaults, overrides))
  end

  def cancel_episode(overrides \\ %{}) do
    defaults = %{
      cancel_ref: "operator-cancel-1",
      episode_key: "grafana:rule-1:fingerprint-1:cycle-1",
      expected_owner: %{kind: :turn, ref: "turn-1"},
      occurred_at: DateTime.add(@occurred_at, 2, :second),
      reason: "Stopped by the operator."
    }

    struct!(Command.CancelEpisode, Map.merge(defaults, overrides))
  end
end
