defmodule Responder.ControlPlane.Actions do
  @moduledoc false

  alias Responder.ControlPlane.ConversationLab
  alias Responder.Delivery.Operator
  alias Responder.Emisar.Operator, as: EmisarOperator
  alias Responder.Ingress.{Inbox, WorkProfile}
  alias Responder.Retention.Operator, as: RetentionOperator
  alias Responder.Slack.{IncidentRooms, InteractionAudits}
  alias Responder.State.{Behaviors, Memories, Schedules}
  alias Responder.Work.Custody

  @actor_ref "control-plane:local"

  @spec callbacks(WorkProfile.t() | nil) :: map()
  def callbacks(work_profile \\ nil) do
    %{
      discard_retention: &discard_retention/1,
      forget_memory: &Memories.forget/1,
      rearm_admission: &Inbox.rearm/1,
      rearm_delivery: &Operator.rearm/1,
      rearm_emisar: &EmisarOperator.rearm/1,
      rearm_retention: &rearm_retention/1,
      rearm_slack_incident: &IncidentRooms.rearm/1,
      rearm_slack_interaction: &InteractionAudits.rearm/1,
      retry_work: &Custody.retry_blocked/1,
      send_lab_message: lab_sender(work_profile),
      set_behavior_status: &Behaviors.set_status/2,
      set_schedule_status: &Schedules.set_status/2
    }
  end

  defp lab_sender(%WorkProfile{} = work_profile) do
    fn conversation_id, message ->
      ConversationLab.send_message(conversation_id, message, work_profile)
    end
  end

  defp lab_sender(_work_profile) do
    fn _conversation_id, _message -> {:error, :conversation_lab_not_configured} end
  end

  defp discard_retention(ref) do
    RetentionOperator.discard_unmerged(ref, @actor_ref, action_ref(:discard_unmerged))
  end

  defp rearm_retention(ref) do
    RetentionOperator.rearm(ref, @actor_ref, action_ref(:rearm))
  end

  defp action_ref(action),
    do: "control-plane:retention:#{action}:#{Ecto.UUID.generate()}"
end
