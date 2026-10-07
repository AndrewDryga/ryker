defmodule Ryker.Knowledge.ConversationKnowledgeQuery do
  @moduledoc "Topics learned in conversations, for every read of `conversation_knowledge`."
  import Ecto.Query
  alias Ryker.Knowledge.ConversationKnowledge

  def all, do: from(topics in ConversationKnowledge, as: :conversation_knowledge)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [conversation_knowledge: k], k.id in ^ids)

  @doc "Topics learned between `from` and `to` and not forgotten, newest first, with their conversation and state."
  def learned_between(from, to) do
    all()
    |> where(
      [conversation_knowledge: k],
      is_nil(k.forgotten_at) and k.inserted_at >= ^from and k.inserted_at < ^to
    )
    |> order_by([conversation_knowledge: k], desc: k.inserted_at, desc: k.id)
    |> select([conversation_knowledge: k], %{conversation: k.conversation_ref, state: k.state})
  end

  def forgotten(queryable),
    do: where(queryable, [conversation_knowledge: k], not is_nil(k.forgotten_at))
end
