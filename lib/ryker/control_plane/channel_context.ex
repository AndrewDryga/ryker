defmodule Ryker.ControlPlane.ChannelContext do
  @moduledoc """
  The context that can affect work in one Slack channel, read at page time.

  Continuity, knowledge and learning key on the canonical `slack:T…` and
  `slack:T…:C…` refs of the channel scope, never the raw pair. Every relation
  is a bounded `PagedRelation`; expiry is applied at read time; nothing here
  accounts a recall or starts learning.
  """

  alias Ryker.Config
  alias Ryker.ControlPlane.{BehaviorLibrary, BehaviorPage, ChannelContext, ChannelScope}
  alias Ryker.ControlPlane.{ConversationMemory, LearningActivity, PagedRelation}
  alias Ryker.Learning.Batch
  alias Ryker.Repo

  @doc """
  Standing rules that target exactly this conversation and are current.

  Rules never inherit: the runtime matches conversation scope only. Paused
  rules stay listed because resuming one changes what happens here; expired,
  superseded and deleted ones live in the library's archive.
  """
  @spec rules(ChannelScope.t(), map()) :: PagedRelation.t()
  def rules(scope, params) do
    relation =
      scope
      |> ChannelContext.Query.rules()
      |> read("rule_page", [desc: :updated_at, desc: :id], params)

    items =
      Enum.map(relation.items, fn behavior ->
        payload = safe_payload(behavior)

        confirmed(behavior, payload)
        |> Map.merge(%{
          title: BehaviorPage.subject(%{kind: :standing_assignment, payload: payload}),
          source_kind: payload["source_kind"],
          repository: payload["repository"],
          task: payload["task"]
        })
      end)

    %{relation | items: items}
  end

  @doc """
  Active preferences effective here through exact, repository or workspace
  scope; the repository is the one the channel's environment changes.
  """
  @spec preferences(ChannelScope.t(), map()) :: PagedRelation.t()
  def preferences(scope, params) do
    relation =
      :preference
      |> ChannelContext.Query.effective_behaviors(scope)
      |> read("preference_page", ChannelContext.Query.inherited_order(), params)

    items =
      Enum.map(relation.items, fn behavior ->
        payload = safe_payload(behavior)

        behavior
        |> confirmed(payload)
        |> Map.merge(%{
          key: payload["key"],
          value: payload["value"],
          library_path: saved_instructions()
        })
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
      scope
      |> ChannelContext.Query.recalled_guidance()
      |> read("guidance_page", ChannelContext.Query.inherited_order(), params)

    items =
      Enum.map(relation.items, fn behavior ->
        payload = safe_payload(behavior)

        Map.merge(confirmed(behavior, payload), %{
          title: BehaviorPage.subject(%{kind: :guidance, payload: payload}),
          summary: payload["summary"],
          text: payload["text"],
          visibility: payload["visibility"],
          library_path: saved_instructions()
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
      scope
      |> ChannelContext.Query.memory()
      |> read("memory_page", ChannelContext.Query.inherited_order(), params)

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

  defp safe_payload(behavior), do: BehaviorLibrary.sanitize(%{payload: behavior.payload}).payload

  # Preferences and guidance are listed, and paged, under one section of the
  # Instructions page; the section is the address that always exists.
  defp saved_instructions, do: "/instructions#saved"

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
      scope
      |> ChannelContext.Query.summaries()
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
          path: ConversationMemory.summary_path(summary.id),
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
    %{
      drafts: Repo.aggregate(ChannelContext.Query.summary_drafts(scope), :count),
      handover_failures: Repo.aggregate(ChannelContext.Query.failed_handovers(scope), :count)
    }
  end

  @doc "Learned knowledge scoped to exactly this conversation, with its recall availability."
  @spec knowledge(ChannelScope.t(), map()) :: PagedRelation.t()
  def knowledge(scope, params) do
    relation =
      scope
      |> ChannelContext.Query.knowledge()
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
          path: ConversationMemory.topic_path(item.id)
        }
      end)

    %{relation | items: items}
  end

  @doc """
  How learning from this conversation stands: messages still waiting to be
  learned from and batches that need a person. Counts only; the batches
  themselves are on the Learning page.
  """
  @spec learning_status(ChannelScope.t()) :: %{
          enabled: boolean(),
          needs_attention: non_neg_integer(),
          waiting: non_neg_integer()
        }
  def learning_status(scope) do
    needs_attention =
      "slack"
      |> Batch.Query.in_conversation(scope.conversation_ref)
      |> Batch.Query.with_statuses([:deferred])
      |> Repo.aggregate(:count)

    %{
      enabled: not is_nil(Config.get_env(:learning)),
      needs_attention: needs_attention,
      waiting: waiting_inputs(scope)
    }
  end

  # Retained messages from this conversation that no settled batch has learned
  # from yet: not yet grouped, or grouped into a batch still in progress.
  defp waiting_inputs(scope) do
    [LearningActivity.Query.unassigned_messages(), LearningActivity.Query.assigned_messages()]
    |> Enum.map(fn query ->
      query
      |> LearningActivity.Query.sent_to("slack", scope.conversation_ref)
      |> Repo.aggregate(:count)
    end)
    |> Enum.sum()
  end

  defp read(query, key, order, params),
    do: PagedRelation.read(query, order, key, params)
end
