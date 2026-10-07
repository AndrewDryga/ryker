defmodule Ryker.Learning.ConversationObservation.Query do
  @moduledoc "What learning observed in conversations, for every read of `conversation_observations`."
  import Ecto.Query
  alias Ryker.Learning.ConversationObservation

  def all, do: from(observations in ConversationObservation, as: :conversation_observations)

  def by_identity(queryable \\ all(), identity_key),
    do: where(queryable, [conversation_observations: o], o.identity_key == ^identity_key)

  def by_identity_keys(queryable \\ all(), identity_keys),
    do: where(queryable, [conversation_observations: o], o.identity_key in ^identity_keys)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [conversation_observations: o], o.id == ^id)

  def by_ids(queryable \\ all(), ids),
    do: where(queryable, [conversation_observations: o], o.id in ^ids)

  def ordered_by_id(queryable), do: order_by(queryable, [conversation_observations: o], asc: o.id)

  def in_workspace(queryable \\ all(), workspace_ref),
    do: where(queryable, [conversation_observations: o], o.workspace_ref == ^workspace_ref)

  @doc "Observations that still say something: a forgotten or conflicted one keeps no note."
  def having_note(queryable),
    do: where(queryable, [conversation_observations: o], not is_nil(o.note))

  @doc "Observations no topic is learned from, by `source_ids`, a query of observation ids."
  def not_among(queryable, source_ids),
    do: where(queryable, [conversation_observations: o], o.id not in subquery(source_ids))

  @doc "This conversation's first, then this repository's, then the latest said."
  def ordered_by_recall_precedence(queryable, scope) do
    order_by(queryable, [conversation_observations: o],
      desc: o.conversation_ref == ^scope.conversation_ref,
      desc: fragment("? IS NOT DISTINCT FROM ?", o.repository_ref, ^scope.repository_ref),
      desc: o.occurred_at,
      desc: o.id
    )
  end

  @doc "Observations within the search scope a recall names: the workspace, this channel or the repository."
  def within_scope(queryable, _scope, "workspace"), do: queryable

  def within_scope(queryable, scope, "current_channel") do
    where(
      queryable,
      [conversation_observations: o],
      o.conversation_ref == ^scope.conversation_ref
    )
  end

  def within_scope(queryable, %{repository_ref: repository}, "repository")
      when is_binary(repository),
      do: where(queryable, [conversation_observations: o], o.repository_ref == ^repository)

  def within_scope(queryable, _scope, _search_scope), do: where(queryable, false)

  def matching(queryable, search) when is_binary(search) do
    search = String.slice(String.trim(search), 0, 200)

    where(
      queryable,
      [conversation_observations: o],
      fragment("position(lower(?) in lower(?)) > 0", ^search, o.note)
    )
  end

  def matching(queryable, _search), do: queryable

  @doc "The fields a memory search reads from an observation (`Ryker.Memories.SearchPage.Query`)."
  def search_fields do
    %{
      text: dynamic([conversation_observations: o], o.note),
      changed: dynamic([conversation_observations: o], o.updated_at),
      source: dynamic([conversation_observations: o], o.occurred_at)
    }
  end

  @doc """
  The upsert of an observation: a later revision of its message replaces it,
  and so does the same revision once routing names its result; a forgotten
  message stays forgotten, so a later edit cannot bring back what learning
  may take from it. `updates` are the fields a replacement sets.
  """
  def monotonic_update(updates) do
    updates = Keyword.delete(updates, :updated_at)

    from(old in ConversationObservation,
      where:
        is_nil(old.forgotten_at) and
          (old.revision < fragment("EXCLUDED.revision") or
             (old.revision == fragment("EXCLUDED.revision") and
                old.source_input_id == fragment("EXCLUDED.source_input_id") and
                old.source_fingerprint == fragment("EXCLUDED.source_fingerprint") and
                is_nil(old.source_result_ref) and
                not is_nil(fragment("EXCLUDED.source_result_ref")))),
      update: [set: ^updates],
      update: [
        set: [
          updated_at:
            fragment(
              "CASE WHEN ? = EXCLUDED.revision THEN ? ELSE EXCLUDED.updated_at END",
              old.revision,
              old.updated_at
            )
        ]
      ]
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_for_share(queryable), do: lock(queryable, "FOR SHARE")

  def in_conversations(queryable \\ all(), conversation_refs),
    do: where(queryable, [conversation_observations: o], o.conversation_ref in ^conversation_refs)

  def by_conversation_ref(queryable, conversation_ref),
    do: where(queryable, [conversation_observations: o], o.conversation_ref == ^conversation_ref)

  def select_ids(queryable), do: select(queryable, [conversation_observations: o], o.id)

  def forgotten(queryable),
    do: where(queryable, [conversation_observations: o], not is_nil(o.forgotten_at))

  def not_forgotten(queryable),
    do: where(queryable, [conversation_observations: o], is_nil(o.forgotten_at))

  def select_messages(queryable) do
    select(
      queryable,
      [conversation_observations: o],
      {o.conversation_ref, o.source_message_ref}
    )
  end
end
