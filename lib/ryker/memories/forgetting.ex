defmodule Ryker.Memories.Forgetting do
  @moduledoc """
  Forgetting what learning kept.

  A person forgets a learned topic on Learned, or a fact on Facts. Either
  way the messages the knowledge came from are forgotten: their observations
  lose their note and are marked forgotten, so every topic and summary that
  cites them stops being used, and learning never takes them again, even
  after an edit. The messages themselves stay valid inputs. A topic left with no message it may still use is forgotten with
  them: its text and history are erased and it stays listed as forgotten. A
  topic that also rests on other messages stops being used until it is
  relearned from those.

  QA re-test, 2026-09-26: after Forget on a fact ("Ryker stops using this
  fact and erases what it saved"), Learned still held the same knowledge,
  learned by background learning from the same message, and a learned topic
  had no way to be forgotten at all.
  """

  import Ecto.Query

  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.Turn

  alias Ryker.Knowledge
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Knowledge.KnowledgeRevision
  alias Ryker.Knowledge.KnowledgeSource
  alias Ryker.Learning
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Learning.Observations
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Records.Record

  @erased %{"retention" => "pruned"}

  @type outcome :: %{forgotten: [Ecto.UUID.t()], relearn: [Ecto.UUID.t()]}

  @doc """
  Forgets one learned topic and the messages it was learned from. The topics
  that goes with (`forgotten`, the topic first) and those that now wait to be
  relearned (`relearn`) are returned.
  """
  @spec forget_topic(Ecto.UUID.t()) :: {:ok, outcome()} | {:error, term()}
  def forget_topic(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.transaction(fn -> forget_topic_locked(id) end)
    end
  end

  defp forget_topic_locked(id) do
    case Repo.one(from(k in ConversationKnowledge, where: k.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:knowledge_not_found)

      %ConversationKnowledge{forgotten_at: %DateTime{}} ->
        %{forgotten: [], relearn: []}

      %ConversationKnowledge{} = topic ->
        outcome = forget_observations_in_transaction(topic_observations(topic.id))
        erase!([topic.id])
        %{outcome | forgotten: Enum.uniq([topic.id | outcome.forgotten])}
    end
  end

  @doc """
  Forgets what learning took from the messages a fact came from, inside the
  transaction that forgets the fact.
  """
  @spec forget_fact_in_transaction(MemoryEntry.t()) :: outcome()
  def forget_fact_in_transaction(%MemoryEntry{} = fact),
    do: forget_observations_in_transaction(fact_observations(fact))

  @doc "What forgetting a topic would also do, for its confirmation."
  @spec preview_topic(Ecto.UUID.t()) :: outcome()
  def preview_topic(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        outcome = preview(topic_observations(id))

        %{
          outcome
          | forgotten: List.delete(outcome.forgotten, id),
            relearn: outcome.relearn -- [id]
        }

      :error ->
        %{forgotten: [], relearn: []}
    end
  end

  @doc "What forgetting a fact would also forget, for its confirmation."
  @spec preview_fact(MemoryEntry.t()) :: outcome()
  def preview_fact(%MemoryEntry{} = fact), do: preview(fact_observations(fact))

  defp forget_observations_in_transaction([]), do: %{forgotten: [], relearn: []}

  defp forget_observations_in_transaction(ids) do
    observations =
      Repo.all(
        from(o in ConversationObservation,
          where: o.id in ^ids and is_nil(o.forgotten_at),
          order_by: o.id,
          lock: "FOR UPDATE"
        )
      )

    now = Repo.now!()
    Enum.each(observations, &quarantine!(&1, now))

    outcome = preview(ids)
    erase!(outcome.forgotten)
    outcome
  end

  # Only what learning may take from the message is gone: its note is erased
  # and it is marked forgotten, which every learning path and the eligibility
  # of derived knowledge check. Its identity and fingerprint stay, so the
  # message itself remains a valid input: Ryker still answers a person who
  # sent it, it just never learns from it again.
  defp quarantine!(observation, now) do
    Repo.update_all(from(o in ConversationObservation, where: o.id == ^observation.id),
      set: [forgotten_at: now, note: nil]
    )

    Learning.broadcast_learning_updated(observation.id)
  end

  # Which topics citing these messages go with them (every message of their
  # current sources is forgotten or among these) and which still rest on
  # other messages.
  defp preview([]), do: %{forgotten: [], relearn: []}

  defp preview(ids) do
    citing =
      Repo.all(
        from(k in ConversationKnowledge,
          join: s in KnowledgeSource,
          on: s.knowledge_id == k.id and s.generation == k.source_generation,
          where: s.observation_id in ^ids and is_nil(k.forgotten_at),
          distinct: true,
          order_by: k.id,
          select: k.id
        )
      )

    remaining =
      Repo.all(
        from(s in KnowledgeSource,
          join: k in ConversationKnowledge,
          on: k.id == s.knowledge_id and k.source_generation == s.generation,
          join: o in ConversationObservation,
          on: o.id == s.observation_id,
          where:
            s.knowledge_id in ^citing and s.observation_id not in ^ids and is_nil(o.forgotten_at),
          distinct: true,
          select: s.knowledge_id
        )
      )

    %{forgotten: citing -- remaining, relearn: Enum.filter(citing, &(&1 in remaining))}
  end

  defp erase!([]), do: :ok

  defp erase!(ids) do
    now = Repo.now!()

    Repo.update_all(from(s in KnowledgeSource, where: s.knowledge_id in ^ids),
      set: [source_note: nil]
    )

    Repo.update_all(from(r in KnowledgeRevision, where: r.knowledge_id in ^ids),
      set: [state: @erased]
    )

    Repo.update_all(from(k in ConversationKnowledge, where: k.id in ^ids),
      set: [state: @erased, forgotten_at: now]
    )

    Enum.each(ids, &Knowledge.broadcast_knowledge_updated/1)
  end

  defp topic_observations(id) do
    Repo.all(
      from(s in KnowledgeSource,
        where: s.knowledge_id == ^id,
        distinct: true,
        select: s.observation_id
      )
    )
  end

  # A fact answered in a message came from that message; one confirmed from
  # an offer came from the message that started the run which made the offer
  # (admission names each run after it).
  defp fact_observations(%MemoryEntry{
         answer_provenance: %{"input_ref" => "ingress-input:" <> id}
       }),
       do: entry_observations([id])

  defp fact_observations(%MemoryEntry{offer_record_id: record_id}) when is_binary(record_id) do
    case Repo.one(
           from(r in Record,
             join: t in Turn,
             on: t.id == r.turn_id,
             where: r.id == ^record_id,
             select: t.turn_ref
           )
         ) do
      "ingress-turn:" <> id -> entry_observations([id])
      _other -> []
    end
  end

  defp fact_observations(_fact), do: []

  defp entry_observations(ids) do
    identities =
      from(e in Entry, where: e.id in ^Enum.filter(ids, &match?({:ok, _}, Ecto.UUID.cast(&1))))
      |> Repo.all()
      |> Enum.map(&Observations.source_identity/1)

    Repo.all(
      from(o in ConversationObservation, where: o.identity_key in ^identities, select: o.id)
    )
  end
end
