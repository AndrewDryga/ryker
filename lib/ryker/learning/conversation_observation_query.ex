defmodule Ryker.Learning.ConversationObservationQuery do
  @moduledoc "What learning observed in conversations, for every read of `conversation_observations`."
  import Ecto.Query
  alias Ryker.Learning.ConversationObservation

  def all, do: from(observations in ConversationObservation, as: :conversation_observations)

  def by_identity(queryable \\ all(), identity_key),
    do: where(queryable, [conversation_observations: o], o.identity_key == ^identity_key)

  def in_conversations(queryable \\ all(), conversation_refs),
    do: where(queryable, [conversation_observations: o], o.conversation_ref in ^conversation_refs)

  def forgotten(queryable),
    do: where(queryable, [conversation_observations: o], not is_nil(o.forgotten_at))

  def select_messages(queryable) do
    select(
      queryable,
      [conversation_observations: o],
      {o.conversation_ref, o.source_message_ref}
    )
  end
end
