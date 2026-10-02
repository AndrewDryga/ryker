defmodule Ryker.ControlPlane.Projection do
  @moduledoc """
  The callback map the router and the workbench bind to, and nothing else.

  Every page's read model lives in its own module; this is the one place that
  lists them. Raw ingress bodies, credentials, and arbitrary state payloads
  never cross any of these boundaries. Model prompts cross only redacted: in
  a request's model calls, and as the routing examples someone chose to keep
  for training, downloaded from Data retention.
  """

  alias Ryker.ControlPlane.{
    Activity,
    BehaviorLibrary,
    ChannelDetail,
    ChannelDirectory,
    ConversationMemory,
    ConversationProjection,
    EpisodeProjection,
    FailureProjection,
    FeedbackProjection,
    FindingsProjection,
    ImprovementProjection,
    IncidentProjection,
    InstructionSettings,
    LearningActivity,
    MemoryProjection,
    ModelRequests,
    OverviewProjection,
    PeopleProjection,
    ProductReadiness,
    RepositoryProjection,
    RunningSystem,
    ScheduleProjection,
    SettingsView,
    SubscriptionProjection,
    UsageProjection,
    WorkspaceProjection
  }

  alias Ryker.Improvement.Export, as: EvalCases
  alias Ryker.RoutingExamples.Export
  alias Ryker.WeeklyReport
  alias Ryker.WorkExamples.Export, as: WorkExamplesExport

  @spec callbacks() :: map()
  def callbacks do
    %{
      activity: &Activity.list/1,
      admission_request: &ModelRequests.project_input/2,
      behavior: &BehaviorLibrary.fetch/1,
      behaviors: &BehaviorLibrary.list/2,
      channel: &ChannelDetail.fetch/3,
      channels: &ChannelDirectory.list/1,
      episode: &EpisodeProjection.fetch/2,
      request_key: &EpisodeProjection.request_key/1,
      request_id: &EpisodeProjection.key_id/1,
      failure: &FailureProjection.fetch/2,
      failures: &FailureProjection.list/1,
      eval_cases: &EvalCases.zip/0,
      feedback: &FeedbackProjection.page/1,
      findings: &FindingsProjection.list/1,
      finding: &FindingsProjection.fetch/1,
      people: &PeopleProjection.list/0,
      person: &PeopleProjection.fetch/1,
      person_fact: &PeopleProjection.fetch_fact/1,
      improvement: &ImprovementProjection.page/1,
      improvement_candidate: &ImprovementProjection.fetch/1,
      incident: &IncidentProjection.fetch/1,
      incidents: &IncidentProjection.list/1,
      instructions: &InstructionSettings.fetch/1,
      lab_artifact: &ConversationProjection.artifact/3,
      lab_changes: &ConversationProjection.changes/3,
      lab_conversation: &ConversationProjection.fetch/1,
      lab_history: &ConversationProjection.history/3,
      lab_index: &ConversationProjection.index/0,
      forgetting: &ConversationMemory.forgetting/1,
      learned: &ConversationMemory.project/1,
      learning: &LearningActivity.project/1,
      memory: &MemoryProjection.fetch/1,
      model_timeline: &ModelRequests.timeline/2,
      running_system: &RunningSystem.fetch/0,
      overview: &OverviewProjection.overview/0,
      readiness: &ProductReadiness.current/0,
      repositories: &RepositoryProjection.list/1,
      repository: &RepositoryProjection.fetch/1,
      repository_detail: &RepositoryProjection.detail/1,
      routing_examples: &Export.reduce/2,
      work_examples: &WorkExamplesExport.reduce/2,
      schedule: &ScheduleProjection.fetch/1,
      schedules: &ScheduleProjection.list/1,
      settings: &SettingsView.fetch/0,
      subscriptions: &SubscriptionProjection.list/1,
      usage: &UsageProjection.page/1,
      usage_filter_options: &UsageProjection.filter_options/0,
      weekly_report_preview: &WeeklyReport.preview/0,
      workspace: &WorkspaceProjection.fetch/1,
      workspace_storage: &WorkspaceProjection.storage/0,
      workspaces: &WorkspaceProjection.list/1
    }
  end
end
