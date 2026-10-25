defmodule Ryker.People.PersonFact.Query do
  @moduledoc "What people said about themselves, for every read of `person_facts`."
  use Ryker, :query
  alias Ryker.ConversationRef
  alias Ryker.People.PersonFact
  alias Ryker.Slack

  def all, do: from(facts in PersonFact, as: :person_facts)

  def by_id(queryable \\ all(), id), do: where(queryable, [person_facts: f], f.id == ^id)

  def by_ids(queryable \\ all(), ids), do: where(queryable, [person_facts: f], f.id in ^ids)

  def by_facts(queryable, facts), do: where(queryable, [person_facts: f], f.fact in ^facts)

  def by_person(queryable \\ all(), person_ref),
    do: where(queryable, [person_facts: f], f.person_ref == ^person_ref)

  def by_keys(queryable \\ all(), keys), do: where(queryable, [person_facts: f], f.key in ^keys)

  def by_source_message(queryable \\ all(), message_ref),
    do: where(queryable, [person_facts: f], f.source_message_ref == ^message_ref)

  def by_conversation(queryable \\ all(), conversation_ref),
    do: where(queryable, [person_facts: f], f.conversation_ref == ^conversation_ref)

  def kept(queryable \\ all()), do: where(queryable, [person_facts: f], f.status == :kept)

  def said_at_or_before(queryable \\ all(), occurred_at)

  def said_at_or_before(queryable, %DateTime{} = occurred_at),
    do: where(queryable, [person_facts: f], f.said_at <= ^occurred_at)

  def said_at_or_before(queryable, _occurred_at), do: where(queryable, false)

  @doc """
  Usable in `conversation_ref`: said where anyone in the workspace can read
  it, or said in that conversation.
  """
  def usable_in(queryable, conversation_ref) do
    case ConversationRef.parse_slack(conversation_ref || "") do
      {:ok, workspace, _channel} -> usable_in_workspace(queryable, conversation_ref, workspace)
      :error -> by_conversation(queryable, conversation_ref || "")
    end
  end

  defp usable_in_workspace(queryable, conversation, workspace) do
    queryable
    |> join(:left, [person_facts: f], c in Slack.ChannelMembership,
      as: :source_channel,
      on:
        f.conversation_ref ==
          fragment("'slack:' || ? || ':' || ?", c.workspace_ref, c.channel_ref)
    )
    |> where(
      [person_facts: f, source_channel: c],
      f.conversation_ref == ^conversation or
        (f.private == false and c.workspace_ref == ^workspace and c.status == :joined and
           c.private == false and c.external_shared == false)
    )
  end

  def ordered_by_person_and_key(queryable \\ all()),
    do: order_by(queryable, [person_facts: f], asc: f.person_ref, asc: f.key)

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
  def lock_for_share_skip_locked(queryable), do: lock(queryable, "FOR SHARE SKIP LOCKED")
end
