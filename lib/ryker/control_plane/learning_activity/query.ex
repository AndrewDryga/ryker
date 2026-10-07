defmodule Ryker.ControlPlane.LearningActivity.Query do
  @moduledoc """
  What the Learning page reads across tables (`Ryker.ControlPlane.LearningActivity`):
  the messages learning has not read yet, the handovers Work could not save,
  the topics an attempt wrote, and the attempts that stopped on a topic.
  """
  import Ecto.Query
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge.{ConversationKnowledge, KnowledgeRevision}
  alias Ryker.Learning.{Batch, InputMembership, LearningRun}
  alias Ryker.Work.Turn

  @doc "The settled messages no batch holds yet."
  def unassigned_messages do
    from(e in Entry,
      as: :input,
      where: e.status in [:decided, :superseded],
      where: not exists(from(m in InputMembership, where: m.input_id == parent_as(:input).id))
    )
  end

  @doc "The messages a batch holds that has not finished, unless their source went away."
  def assigned_messages do
    from(e in Entry,
      as: :input,
      join: m in InputMembership,
      on: m.input_id == e.id,
      join: b in Batch,
      on: b.id == m.batch_id,
      where:
        b.status in [:queued, :running, :deferred] and
          (is_nil(m.terminal_reason) or m.terminal_reason != "source_unavailable")
    )
  end

  @doc "The messages of `query` sent to `conversation_ref` on `transport`."
  def sent_to(queryable, transport, conversation_ref) do
    where(
      queryable,
      [input: e],
      e.destination_transport == ^transport and
        e.destination_conversation_ref == ^conversation_ref
    )
  end

  @doc "How many messages `query` holds and when the oldest last changed, as `{count, oldest}`."
  def select_count_and_oldest(queryable),
    do: select(queryable, [input: e], {count(e.id), min(e.updated_at)})

  @doc "Accepted answers whose conversation summary could not be saved, with their request."
  def failed_handovers do
    from(t in Turn,
      join: e in Episode,
      on: e.id == t.episode_id,
      where: not is_nil(t.summary_error_code),
      select: %{
        turn_id: t.id,
        episode_id: e.id,
        conversation: e.destination_conversation_ref,
        accepted_at: t.accepted_at,
        delivered_at: t.delivered_at,
        error_code: t.summary_error_code
      }
    )
  end

  @doc """
  The topics attempt `run_id` wrote, as `{topic_key, knowledge_id}`: each
  revision names the attempt that wrote it (`learning:<attempt>:<result
  digest>`).
  """
  def topics_written(run_id) do
    from(revision in KnowledgeRevision,
      join: knowledge in ConversationKnowledge,
      on: knowledge.id == revision.knowledge_id,
      where: like(revision.source_result_ref, ^"learning:#{run_id}:%"),
      select: {knowledge.topic_key, knowledge.id}
    )
  end

  @doc "The error of each of `batch_ids`' latest failed attempt, as `{batch_id, error_code}`."
  def latest_errors(batch_ids) do
    from(r in LearningRun,
      where: r.batch_id in ^batch_ids and not is_nil(r.error_code),
      distinct: r.batch_id,
      order_by: [asc: r.batch_id, desc: r.inserted_at, desc: r.id],
      select: {r.batch_id, r.error_code}
    )
  end
end
