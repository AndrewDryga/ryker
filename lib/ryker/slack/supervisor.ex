defmodule Ryker.Slack.Supervisor do
  @moduledoc false
  use Supervisor
  alias Ryker.Slack.{ActionTokens, Gateway, IncidentRoomWorker, InteractionFeedbackWorker}
  alias Ryker.Slack.{MembershipReconciler, Runtime, TaskCardWorker, ThreadStatusWorker}
  alias Ryker.Slack.WorkspaceAdmins
  alias Ryker.Transcription

  def start_link(options), do: Supervisor.start_link(__MODULE__, options, name: __MODULE__)

  @impl Supervisor
  def init(%{
        action_tokens: action_tokens,
        gateway: gateway,
        incident_worker: incident_worker,
        interaction_feedback_worker: interaction_feedback_worker,
        reconciler: reconciler,
        task_card_worker: task_card_worker,
        thread_status_worker: thread_status_worker,
        transcription_worker: transcription_worker,
        workspace_admins: workspace_admins
      }) do
    Supervisor.init(
      [
        {ActionTokens, action_tokens},
        # Before anything that hears Slack asks who can manage Ryker.
        {WorkspaceAdmins, workspace_admins},
        {Gateway, gateway},
        {Transcription.Worker, transcription_worker},
        {MembershipReconciler, reconciler},
        {IncidentRoomWorker, incident_worker},
        {InteractionFeedbackWorker, interaction_feedback_worker},
        {TaskCardWorker, task_card_worker},
        {ThreadStatusWorker, thread_status_worker},
        {Task.Supervisor, name: Runtime.tasks()}
      ],
      strategy: :one_for_one
    )
  end
end
