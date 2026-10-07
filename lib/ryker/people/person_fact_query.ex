defmodule Ryker.People.PersonFactQuery do
  @moduledoc "What people said about themselves, for every read of `person_facts`."
  import Ecto.Query
  alias Ryker.People.PersonFact

  def all, do: from(facts in PersonFact, as: :person_facts)

  def by_id(queryable \\ all(), id), do: where(queryable, [person_facts: f], f.id == ^id)

  def by_person(queryable \\ all(), person_ref),
    do: where(queryable, [person_facts: f], f.person_ref == ^person_ref)

  def by_keys(queryable \\ all(), keys), do: where(queryable, [person_facts: f], f.key in ^keys)

  def by_source_message(queryable \\ all(), message_ref),
    do: where(queryable, [person_facts: f], f.source_message_ref == ^message_ref)

  def by_conversation(queryable \\ all(), conversation_ref),
    do: where(queryable, [person_facts: f], f.conversation_ref == ^conversation_ref)

  def kept(queryable \\ all()), do: where(queryable, [person_facts: f], f.status == :kept)

  @doc """
  Usable in `conversation_ref`: said where anyone in the workspace can read
  it, or said in that conversation.
  """
  def usable_in(queryable, conversation_ref) do
    where(
      queryable,
      [person_facts: f],
      f.private == false or f.conversation_ref == ^(conversation_ref || "")
    )
  end

  def ordered_by_key(queryable), do: order_by(queryable, [person_facts: f], asc: f.key)
  def limit_to(queryable, count), do: limit(queryable, ^count)
  def select_facts(queryable), do: select(queryable, [person_facts: f], f.fact)

  def select_keyed_facts(queryable),
    do: select(queryable, [person_facts: f], %{"key" => f.key, "fact" => f.fact})

  @doc "Everyone with a kept fact: how many, when they last said one, and one place they said it."
  def people do
    kept()
    |> group_by([person_facts: f], f.person_ref)
    |> order_by([person_facts: f], desc: max(f.said_at), asc: f.person_ref)
    |> select([person_facts: f], %{
      person_ref: f.person_ref,
      facts: count(f.id),
      last_said_at: max(f.said_at),
      conversation_ref: max(f.conversation_ref)
    })
  end

  @doc """
  The update that forgets each fact `queryable` selects at `now`: its kind
  becomes a digest of the person and the kind, and what was said goes.
  """
  def forget_at(queryable, now) do
    update(queryable, [person_facts: f],
      set: [
        key:
          fragment(
            "'f' || left(encode(sha256(convert_to(? || chr(10) || ?, 'UTF8')), 'hex'), 47)",
            f.person_ref,
            f.key
          ),
        status: :forgotten,
        fact: nil,
        forgotten_at: ^now,
        updated_at: ^now
      ]
    )
  end

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
