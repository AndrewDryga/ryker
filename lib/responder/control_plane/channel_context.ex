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
    BehaviorLibrary,
    BehaviorPage,
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
    Behavior,
    ConversationKnowledge,
    ConversationRollup,
    ConversationSummary,
    ConversationSummaryDraft,
    MemoryEntry
  }

  alias Responder.Work.Turn

  @batch_states ~w(queued running applied no_change deferred superseded)a

  @doc """
  Standing rules that target exactly this conversation and are current.

  Rules never inherit: the runtime matches conversation scope only. Paused
  rules stay listed because resuming one changes what happens here; expired,
  superseded and deleted ones live in the library's archive.
  """
  @spec rules(ChannelScope.t(), map()) :: PagedRelation.t()
  def rules(scope, params) do
    relation =
      from(behavior in Behavior,
        where:
          behavior.kind == :standing_assignment and
            behavior.workspace_ref == ^scope.canonical_workspace_ref and
            behavior.scope_kind == :conversation and
            behavior.scope_ref == ^scope.conversation_ref and
            behavior.status in [:active, :disabled] and
            (is_nil(behavior.expires_at) or behavior.expires_at > fragment("clock_timestamp()"))
      )
      |> read("rule_page", [desc: :updated_at, desc: :id], params)

    items =
      Enum.map(relation.items, fn behavior ->
        payload = safe_payload(behavior)

        confirmed(behavior, payload)
        |> Map.merge(%{
          title: BehaviorPage.subject(%{kind: :standing_assignment, payload: payload}),
          trigger: payload["trigger"] || payload["source_kind"],
          source_filter: payload["source_filter"],
          repository: payload["repository"],
          task: payload["task"]
        })
      end)

    %{relation | items: items}
  end

  @doc "Active preferences effective here through exact, configured-repository or workspace scope."
  @spec preferences(ChannelScope.t(), map()) :: PagedRelation.t()
  def preferences(scope, params) do
    relation =
      :preference
      |> effective_behaviors(scope)
      |> read("preference_page", inherited_order(), params)

    items =
      Enum.map(relation.items, fn behavior ->
        payload = safe_payload(behavior)
        Map.merge(confirmed(behavior, payload), %{key: payload["key"], value: payload["value"]})
      end)

    %{relation | items: items}
  end

  @doc """
  Active guidance recalled here under the runtime visibility rules.

  Workspace-visible guidance reaches every conversation in its scope;
  conversation- or private-visible guidance reaches only the conversation
  that confirmed it. Operator-scoped guidance needs an actor and is never shown.
  """
  @spec guidance(ChannelScope.t(), map()) :: PagedRelation.t()
  def guidance(scope, params) do
    relation =
      :guidance
      |> effective_behaviors(scope)
      |> where(
        [behavior],
        fragment("(?::jsonb)->>'visibility'", behavior.payload) == "workspace" or
          (fragment("(?::jsonb)->>'visibility' IN ('conversation', 'private')", behavior.payload) and
             behavior.source_conversation_ref == ^scope.conversation_ref)
      )
      |> read("guidance_page", inherited_order(), params)

    items =
      Enum.map(relation.items, fn behavior ->
        payload = safe_payload(behavior)

        Map.merge(confirmed(behavior, payload), %{
          title: BehaviorPage.subject(%{kind: :guidance, payload: payload}),
          summary: payload["summary"],
          text: payload["text"],
          visibility: payload["visibility"]
        })
      end)

    %{relation | items: items}
  end

  @doc """
  Operational memory the runtime would recall here, read without accounting a recall.

  Conversation-visible entries reach only the conversation that confirmed
  them; workspace-visible entries reach their whole scope; global facts reach
  every workspace.
  """
  @spec memory(ChannelScope.t(), map()) :: PagedRelation.t()
  def memory(scope, params) do
    relation =
      from(entry in MemoryEntry,
        where:
          entry.status == :active and
            (is_nil(entry.expires_at) or entry.expires_at > fragment("clock_timestamp()")),
        where: ^memory_scope(scope),
        where:
          entry.visibility in [:workspace, :global] or
            (entry.visibility == :conversation and
               entry.source_conversation_ref == ^scope.conversation_ref)
      )
      |> read("memory_page", inherited_order(), params)

    items =
      Enum.map(relation.items, fn entry ->
        payload = BehaviorLibrary.sanitize(%{payload: entry.payload}).payload

        %{
          ref: entry.ref,
          kind: entry.kind,
          subject: entry.subject,
          value: payload["value"],
          applicability: payload["applicability"],
          scope: entry.scope_kind,
          scope_ref: entry.scope_ref,
          visibility: entry.visibility,
          expires_at: entry.expires_at,
          confirmed_at: entry.confirmed_at,
          recall_count: entry.recall_count,
          last_recalled_at: entry.last_recalled_at,
          source_url: BehaviorPage.source_url(entry),
          library_path: "/memory"
        }
      end)

    %{relation | items: items}
  end

  defp memory_scope(scope) do
    dynamic(
      [entry],
      entry.scope_kind == :global or
        (entry.workspace_ref == ^scope.canonical_workspace_ref and ^scoped(scope))
    )
  end

  defp effective_behaviors(kind, scope) do
    from(behavior in Behavior,
      where:
        behavior.kind == ^kind and behavior.status == :active and
          behavior.workspace_ref == ^scope.canonical_workspace_ref and
          (is_nil(behavior.expires_at) or behavior.expires_at > fragment("clock_timestamp()")),
      where: ^scoped(scope)
    )
  end

  # Exact conversation, the configured repository when there is one, or the
  # workspace. Operator scope needs an actor context the page does not have.
  defp scoped(%ChannelScope{repository_ref: repository} = scope) when is_binary(repository) do
    dynamic(
      [row],
      (row.scope_kind == :conversation and row.scope_ref == ^scope.conversation_ref) or
        (row.scope_kind == :repository and row.scope_ref == ^repository) or
        (row.scope_kind == :workspace and row.scope_ref == ^scope.canonical_workspace_ref)
    )
  end

  defp scoped(scope) do
    dynamic(
      [row],
      (row.scope_kind == :conversation and row.scope_ref == ^scope.conversation_ref) or
        (row.scope_kind == :workspace and row.scope_ref == ^scope.canonical_workspace_ref)
    )
  end

  # Most specific first, as the runtime resolves precedence; then newest.
  defp inherited_order do
    [
      asc:
        dynamic(
          [row],
          fragment(
            "CASE ? WHEN 'conversation' THEN 0 WHEN 'repository' THEN 1 WHEN 'workspace' THEN 2 ELSE 3 END",
            row.scope_kind
          )
        ),
      desc: :updated_at,
      desc: :id
    ]
  end

  defp safe_payload(behavior), do: BehaviorLibrary.sanitize(%{payload: behavior.payload}).payload

  defp confirmed(behavior, payload) do
    %{
      ref: behavior.ref,
      status: Atom.to_string(behavior.status),
      scope: behavior.scope_kind,
      scope_ref: behavior.scope_ref,
      repository: payload["repository"],
      expires_at: behavior.expires_at,
      use_count: behavior.use_count,
      last_used_at: behavior.last_used_at,
      confirmed_at: behavior.confirmed_at,
      source_url: BehaviorPage.source_url(behavior),
      library_path: BehaviorLibrary.path(behavior.kind) <> "#behavior-" <> behavior.ref
    }
  end

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
