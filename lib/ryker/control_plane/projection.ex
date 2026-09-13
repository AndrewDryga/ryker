defmodule Ryker.ControlPlane.Projection do
  @moduledoc """
  The callback map the router and the workbench bind to, and nothing else.

  Every page's read model lives in its own module; this is the one place that
  lists them. Raw ingress bodies, model prompts, credentials, and arbitrary
  state payloads never cross any of these boundaries.
  """

  alias Ryker.ControlPlane.{
    Activity,
    BehaviorLibrary,
    ChannelDetail,
    ConversationProjection,
    EpisodeProjection,
    FailureProjection,
    FindingsProjection,
    InstructionSettings,
    MemoryProjection,
    ModelRequests,
    OperatorProjection,
    OverviewProjection,
    SettingsView,
    UsageProjection,
    WorkspaceProjection
  }

  @spec callbacks() :: map()
  def callbacks do
    %{
      activity: &Activity.list/1,
      admission: &FailureProjection.admission/1,
      admission_request: &ModelRequests.project_input/2,
      behavior: &BehaviorLibrary.fetch/1,
      behaviors: &BehaviorLibrary.list/2,
      channel: &ChannelDetail.fetch/3,
      channels: &OperatorProjection.channels/1,
      delivery: &FailureProjection.delivery/1,
      emisar: &FailureProjection.emisar/1,
      episode: &EpisodeProjection.fetch/2,
      failures: &FailureProjection.list/1,
      findings: &FindingsProjection.list/1,
      incident: &OperatorProjection.incident/1,
      incidents: &OperatorProjection.incidents/1,
      instructions: &InstructionSettings.fetch/1,
      lab_artifact: &ConversationProjection.artifact/3,
      lab_changes: &ConversationProjection.changes/3,
      lab_conversation: &ConversationProjection.fetch/1,
      lab_history: &ConversationProjection.history/3,
      lab_index: &ConversationProjection.index/0,
      memory: &MemoryProjection.fetch/1,
      model_requests: &ModelRequests.project/2,
      model_timeline: &ModelRequests.timeline/2,
      operator_configuration: &OperatorProjection.operator_configuration/0,
      overview: &OverviewProjection.overview/0,
      repositories: &OperatorProjection.repositories/1,
      schedule: &OperatorProjection.schedule/1,
      schedules: &OperatorProjection.schedules/1,
      settings: &SettingsView.fetch/0,
      slack_incident: &FailureProjection.slack_incident/1,
      slack_interaction: &FailureProjection.slack_interaction/1,
      subscriptions: &OperatorProjection.subscriptions/1,
      usage: &UsageProjection.page/1,
      usage_filter_options: &UsageProjection.filter_options/0,
      work: &FailureProjection.work/1,
      workspace: &WorkspaceProjection.fetch/1,
      workspace_storage: &WorkspaceProjection.storage/0,
      workspaces: &WorkspaceProjection.list/1
    }
  end

  defdelegate admission(ref), to: FailureProjection
  defdelegate channel(workspace_ref, channel_ref, params), to: ChannelDetail, as: :fetch
  defdelegate channels(params), to: OperatorProjection
  defdelegate delivery(ref), to: FailureProjection
  defdelegate emisar(ref), to: FailureProjection
  defdelegate episode(ref, params \\ %{}), to: EpisodeProjection, as: :fetch
  defdelegate failures(params), to: FailureProjection, as: :list
  defdelegate findings(params), to: FindingsProjection, as: :list
  defdelegate incident(ref), to: OperatorProjection
  defdelegate incidents(params), to: OperatorProjection

  defdelegate lab_artifact(conversation_id, turn_id, artifact_ref),
    to: ConversationProjection,
    as: :artifact

  defdelegate lab_changes(conversation_id, since, limit \\ ConversationProjection.page_size()),
    to: ConversationProjection,
    as: :changes

  defdelegate lab_conversation(conversation_id), to: ConversationProjection, as: :fetch

  defdelegate lab_history(conversation_id, cursor, limit \\ ConversationProjection.page_size()),
    to: ConversationProjection,
    as: :history

  defdelegate lab_index(), to: ConversationProjection, as: :index
  defdelegate memory(params \\ %{}), to: MemoryProjection, as: :fetch
  defdelegate operator_configuration(), to: OperatorProjection
  defdelegate overview(), to: OverviewProjection
  defdelegate repositories(params), to: OperatorProjection
  defdelegate schedule(ref), to: OperatorProjection
  defdelegate schedules(params), to: OperatorProjection
  defdelegate slack_incident(ref), to: FailureProjection
  defdelegate slack_interaction(ref), to: FailureProjection
  defdelegate subscriptions(params), to: OperatorProjection
  defdelegate usage(params), to: UsageProjection, as: :page
  defdelegate work(ref), to: FailureProjection
  defdelegate workspace(ref), to: WorkspaceProjection, as: :fetch
  defdelegate workspace_storage(), to: WorkspaceProjection, as: :storage
  defdelegate workspaces(params), to: WorkspaceProjection, as: :list
end
