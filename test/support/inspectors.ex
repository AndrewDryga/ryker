defmodule Ryker.Inspectors do
  @moduledoc """
  Reads tests use to look at what a flow saved, each a row or nil the way a
  test asserts on it. They live here because no context function exists only
  for its tests (Emisar's rule, `.agent/kb/rules/elixir-layered-contexts.md`):
  until 2026-10-07 these were public functions of the contexts that nothing
  else called.
  """
  alias Ryker.Behaviors.StandingRuleInventory
  alias Ryker.CoopFleet.SessionEvidence
  alias Ryker.Emisar.Approval
  alias Ryker.Episodes.{CorrelationClaim, Episode, Event, RoutingDigest}
  alias Ryker.Improvement.Candidate
  alias Ryker.Knowledge.KnowledgeRevision
  alias Ryker.Memories
  alias Ryker.Memories.MemoryReviewItem
  alias Ryker.Repo
  alias Ryker.RepositoryKnowledge.Entry
  alias Ryker.Slack.{ChannelConfiguration, ChannelMembership}

  @doc "The episode with `key`, or nil. Production reads go through the kernel's own loads."
  def episode(key), do: key |> Episode.Query.by_key() |> Repo.one()

  @doc "The events of the episode with `key`, in sequence order."
  def episode_events(key), do: key |> Event.Query.by_episode_key() |> Repo.all()

  @doc "A learned topic's revisions, oldest first, by its `knowledge:` source ref."
  def knowledge_history("knowledge:" <> id) do
    id
    |> KnowledgeRevision.Query.by_knowledge_id()
    |> KnowledgeRevision.Query.ordered_by_version()
    |> Repo.all()
  end

  @doc "The self-analysis candidate about a request, or nil."
  def improvement_candidate({:episode, id}), do: Repo.one(Candidate.Query.by_episode_id(id))
  def improvement_candidate({:input, id}), do: Repo.one(Candidate.Query.by_input_id(id))

  @doc "The approval watch Emisar knows as `request_id` on a connection, or nil."
  def emisar_approval(connection_ref, request_id),
    do: connection_ref |> Approval.Query.by_request(request_id) |> Repo.one()

  @doc "The rule inventory recorded for one input, or nil."
  def rule_inventory(input_ref),
    do: input_ref |> StandingRuleInventory.Query.by_source_input_ref() |> Repo.one()

  @doc "An episode's routing digest, or nil."
  def routing_digest(episode_id), do: Repo.one(RoutingDigest.Query.by_episode_id(episode_id))

  @doc "A repository's knowledge entry, or nil before its first check."
  def repository_knowledge(ref), do: Repo.one(Entry.Query.by_repository(ref))

  @doc "A Slack channel's saved configuration, or nil."
  def channel_configuration(workspace_ref, channel_ref),
    do: Repo.one(ChannelConfiguration.Query.by_channel(workspace_ref, channel_ref))

  @doc "Ryker's membership of a Slack channel, or nil."
  def channel_membership(workspace_ref, channel_ref),
    do: Repo.one(ChannelMembership.Query.by_channel(workspace_ref, channel_ref))

  @doc "Every Coop evidence capture recorded for a session."
  def session_evidences(session_id),
    do: Repo.all(SessionEvidence.Query.by_session_id(session_id))

  @doc "The active claim on one occurrence, or nil."
  def correlation_owner(scope_ref, namespace, occurrence_ref) do
    scope_ref
    |> CorrelationClaim.Query.by_occurrence(namespace, occurrence_ref)
    |> CorrelationClaim.Query.active()
    |> Repo.one()
  end

  @doc "A workspace's pending memory reviews, oldest first, each as the console reads it."
  def memory_reviews(workspace_ref) do
    workspace_ref
    |> MemoryReviewItem.Query.by_workspace()
    |> MemoryReviewItem.Query.pending()
    |> MemoryReviewItem.Query.ordered_by_oldest()
    |> Repo.all()
    |> Enum.map(&Memories.pending_review(&1.ref))
  end
end
