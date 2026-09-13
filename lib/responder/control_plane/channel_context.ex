defmodule Responder.ControlPlane.ChannelContext do
  @moduledoc """
  The context that can affect work in one Slack channel, read at page time.

  Continuity, knowledge and learning key on the canonical `slack:T…` and
  `slack:T…:C…` refs of the channel scope, never the raw pair. Every relation
  is a bounded `PagedRelation`; expiry is applied at read time; nothing here
  accounts a recall or starts learning.
  """

  import Ecto.Query

  alias Responder.ControlPlane.{
    ChannelScope,
    ConversationMemory,
    InspectionRedactor,
    LearningActivity,
    PagedRelation
  }

  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Learning.{Batch, InputMembership}
  alias Responder.Repo

  alias Responder.State.{
    ConversationKnowledge,
    ConversationRollup,
    ConversationSummary,
    ConversationSummaryDraft
  }

  alias Responder.Work.Turn

  @batch_states ~w(queued running applied no_change deferred superseded)a

  @doc "Durable summaries of this conversation, newest first, presented as `/memory` presents them."
  @spec summaries(ChannelScope.t(), map()) :: PagedRelation.t()
  def summaries(scope, params) do
    relation =
      from(summary in ConversationSummary,
        where:
          summary.transport == "slack" and
            summary.workspace_ref == ^scope.canonical_workspace_ref and
            summary.conversation_ref == ^scope.conversation_ref
      )
      |> read("summary_page", [desc: :updated_at, desc: :id], params)

    items =
      relation.items
      |> ConversationMemory.present()
      |> Enum.zip_with(relation.items, fn presented, summary ->
        presented
        |> Map.drop([
          :id,
          :conversation,
          :conversation_path,
          :workspace,
          :at,
          :changed_at,
          :repository
        ])
        |> Map.merge(%{
          ref: summary.ref,
          thread_ref: summary.thread_ref,
          repository_ref: summary.repository_ref,
          updated_at: summary.updated_at,
          recall_count: summary.recall_count,
          last_recalled_at: summary.last_recalled_at,
          source: ConversationMemory.source_message(summary)
        })
      end)

    %{relation | items: items}
  end

  @doc "In-flight summary drafts and unsaved handovers for this conversation: counts, never payloads."
  @spec continuity(ChannelScope.t()) :: %{
          drafts: non_neg_integer(),
          handover_failures: non_neg_integer()
        }
  def continuity(scope) do
    drafts =
      from(draft in ConversationSummaryDraft,
        join: episode in Episode,
        on: episode.id == draft.episode_id
      )

    failures =
      from(turn in Turn,
        join: episode in Episode,
        on: episode.id == turn.episode_id,
        where: not is_nil(turn.summary_error_code)
      )

    %{
      drafts: Repo.aggregate(delivered_to(drafts, scope), :count),
      handover_failures: Repo.aggregate(delivered_to(failures, scope), :count)
    }
  end

  defp delivered_to(query, scope) do
    from([_row, episode] in query,
      where:
        episode.destination_transport == "slack" and
          episode.destination_conversation_ref == ^scope.conversation_ref
    )
  end

  @doc "Unexpired compacted continuity scoped to exactly this conversation."
  @spec rollups(ChannelScope.t(), map()) :: PagedRelation.t()
  def rollups(scope, params) do
    relation =
      from(rollup in ConversationRollup,
        where:
          rollup.workspace_ref == ^scope.canonical_workspace_ref and
            rollup.scope_kind == :conversation and
            rollup.scope_ref == ^scope.conversation_ref and
            rollup.expires_at > fragment("clock_timestamp()"),
        select: %{
          expires_at: rollup.expires_at,
          last_recalled_at: rollup.last_recalled_at,
          period_end: rollup.period_end,
          period_start: rollup.period_start,
          recall_count: rollup.recall_count,
          ref: rollup.ref,
          repository_ref: rollup.repository_ref,
          source_count: rollup.source_count,
          state: rollup.state,
          updated_at: rollup.updated_at
        }
      )
      |> read("rollup_page", [desc: :period_end, desc: :id], params)

    secrets = InspectionRedactor.configured_secrets()

    items =
      Enum.map(relation.items, fn rollup ->
        rollup
        |> Map.delete(:state)
        |> Map.merge(ConversationMemory.continuity_state(rollup.state, secrets))
      end)

    %{relation | items: items}
  end

  @doc "Learned knowledge scoped to exactly this conversation, with its recall availability."
  @spec knowledge(ChannelScope.t(), map()) :: PagedRelation.t()
  def knowledge(scope, params) do
    relation =
      from(item in ConversationKnowledge,
        where:
          item.transport == "slack" and
            item.workspace_ref == ^scope.canonical_workspace_ref and
            item.conversation_ref == ^scope.conversation_ref
      )
      |> read("knowledge_page", [desc: :updated_at, desc: :id], params)

    available = ConversationMemory.available_ids(relation.items)

    items =
      relation.items
      |> ConversationMemory.present()
      |> Enum.zip_with(relation.items, fn presented, item ->
        %{
          id: item.id,
          title: presented.title,
          text: presented.text,
          version: item.version,
          available: MapSet.member?(available, item.id),
          updated_at: item.updated_at,
          source_at: item.latest_source_at,
          expires_at: presented.expires_at,
          request_path: presented.request_path,
          path: "/memory?" <> URI.encode_query(%{"kind" => "knowledge", "item" => item.id})
        }
      end)

    %{relation | items: items}
  end

  @doc """
  Learning batches for exactly this conversation, with the queue health beside them.

  Runs and attempts stay behind each batch on the learning inspection.
  """
  @spec learning(ChannelScope.t(), map()) :: map()
  def learning(scope, params) do
    batches =
      from(batch in Batch,
        where: batch.transport == "slack" and batch.conversation_ref == ^scope.conversation_ref
      )

    relation = read(batches, "learning_page", [desc: :inserted_at, desc: :id], params)

    counts =
      Map.new(@batch_states, &{&1, 0})
      |> Map.merge(
        Map.new(
          Repo.all(
            from(batch in batches,
              group_by: batch.status,
              select: {batch.status, count(batch.id)}
            )
          )
        )
      )

    Map.merge(relation, %{
      items: Enum.map(relation.items, &LearningActivity.batch/1),
      counts: counts,
      waiting_inputs: waiting_inputs(scope),
      enabled: not is_nil(Application.get_env(:responder, :learning))
    })
  end

  # Retained messages from this conversation that no settled batch has learned
  # from yet: not yet grouped, or grouped into a batch still in progress.
  defp waiting_inputs(scope) do
    pending =
      from(entry in Entry,
        as: :input,
        where:
          entry.destination_transport == "slack" and
            entry.destination_conversation_ref == ^scope.conversation_ref and
            entry.status in [:decided, :superseded],
        where:
          not exists(
            from(membership in InputMembership,
              where: membership.input_id == parent_as(:input).id
            )
          )
      )

    assigned =
      from(entry in Entry,
        join: membership in InputMembership,
        on: membership.input_id == entry.id,
        join: batch in Batch,
        on: batch.id == membership.batch_id,
        where:
          entry.destination_transport == "slack" and
            entry.destination_conversation_ref == ^scope.conversation_ref and
            batch.status in [:queued, :running, :deferred] and
            (is_nil(membership.terminal_reason) or
               membership.terminal_reason != "source_unavailable")
      )

    Repo.aggregate(pending, :count) + Repo.aggregate(assigned, :count)
  end

  defp read(query, key, order, params),
    do: PagedRelation.read(query, order, key, PagedRelation.requested(params, key))
end
