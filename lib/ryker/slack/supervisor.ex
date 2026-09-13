defmodule Ryker.Slack.Supervisor do
  @moduledoc false

  use Supervisor

  alias Ryker.Slack.{
    ActionTokens,
    Gateway,
    IncidentRoomWorker,
    InteractionFeedbackWorker,
    MembershipReconciler,
    TaskCardWorker,
    ThreadStatusWorker
  }

  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl Supervisor
  def init(%{
        action_tokens: action_tokens,
        gateway: gateway,
        incident_worker: incident_worker,
        interaction_feedback_worker: interaction_feedback_worker,
        reconciler: reconciler,
        task_card_worker: task_card_worker,
        thread_status_worker: thread_status_worker
      }) do
    Supervisor.init(
      [
        {ActionTokens, action_tokens},
        {Gateway, gateway},
        {MembershipReconciler, reconciler},
        {IncidentRoomWorker, incident_worker},
        {InteractionFeedbackWorker, interaction_feedback_worker},
        {TaskCardWorker, task_card_worker},
        {ThreadStatusWorker, thread_status_worker}
      ],
      strategy: :one_for_one
    )
  end
end
