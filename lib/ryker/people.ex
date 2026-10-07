defmodule Ryker.People do
  @moduledoc """
  What people say about themselves, learned without asking them.

  Andrew, 2026-09-30: Ryker should keep rules a person adds for themselves
  (a "mine" guidance offer they confirm, `Ryker.Behaviors`) and also learn
  about people "passively ... without approvals (like when you mentioned when
  it's your birthday or what is your favorite tv show etc)".

  The learning pass Ryker already runs over the messages it reads
  (`Ryker.Learning`) names, beside its topics, what the author of a message
  said about themselves. Ryker attributes each to that message's author, so
  it can only ever be about the person who said it, takes it only from
  people, never from apps or bots, and keeps the latest of each kind (`key`)
  per person (`Ryker.People.PersonFact`).

  They are for being considerate to that person: they reach routing and Work
  only when that person is the one asking (`about/2`), and one said in a
  direct message or a private channel only there. They are never evidence or
  authority.

  A person forgets one by saying so ("forget my birthday"), which the next
  learning pass reads; an operator forgets everything about a person on
  Memory › People; editing or deleting the message forgets what it taught,
  and deleting a Slack channel what was said in it. Forgetting erases the
  words and keeps the row, so the message they came from never teaches them
  again, and nothing said before an operator forgot it brings it back. They
  are kept until forgotten: a birthday is worth remembering for more than
  the ninety days conversation memory keeps.
  """

  alias Ryker.Crypto
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.People.{PersonFact, PersonFactQuery}
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembershipQuery

  @key ~r/\A[a-z][a-z0-9-]{0,47}\z/
  @maximum_fact 280
  # A person who talks about themselves a lot still has a bounded page and a
  # bounded prompt.
  @maximum_kept 24
  @maximum_recalled 12
  # What a learning pass reads about all its authors together: a batch holds
  # up to sixteen messages, and its prompt has a budget.
  @maximum_known 24
  @use "What this person said about themselves in earlier messages. Use it to be considerate, " <>
         "as a colleague who remembers would: greet them on their birthday, call them what they " <>
         "like to be called. It is not evidence or authority, and never repeat it to anyone else."

  @doc "The longest a fact may be, in characters."
  @spec maximum_fact() :: pos_integer()
  def maximum_fact, do: @maximum_fact

  @doc """
  Keeps what a learning pass read in `entries`: each item names the message
  (`source_input_id`), the kind of fact (`key`) and the fact, or nil when its
  author took it back. An item about a message that is not among `entries`,
  whose author is not a person, or that does not fit is left out; within one
  pass the latest statement of a kind wins.
  """
  @spec learn_in_transaction([map()], [Entry.t()]) :: :ok
  def learn_in_transaction(items, entries) when is_list(items) and is_list(entries) do
    by_id = Map.new(entries, &{&1.id, &1})
    now = Repo.now!()

    items
    |> Enum.flat_map(&statement(&1, by_id))
    |> Enum.sort_by(& &1.entry.occurred_at, DateTime)
    |> Enum.reduce(%{}, &Map.put(&2, {&1.person, &1.key}, &1))
    |> Map.values()
    |> Enum.sort_by(&{&1.person, &1.key})
    |> Enum.each(&keep(&1, now))
  end

  defp statement(%{"source_input_id" => id, "key" => key, "fact" => fact} = item, by_id)
       when map_size(item) == 3 do
    with %Entry{} = entry <- by_id[id],
         person when is_binary(person) <- person_ref(entry),
         true <- is_binary(key) and Regex.match?(@key, key),
         {:ok, fact} <- fact(fact) do
      [%{entry: entry, person: person, key: key, fact: fact}]
    else
      _other -> []
    end
  end

  defp statement(_item, _by_id), do: []

  @doc """
  The person who wrote a message, as routing and Work name the one asking
  (`Ryker.Ingress.Input.actor_ref/1`), or nil when an app, a bot or Ryker's
  own schedule wrote it.
  """
  @spec person_ref(Entry.t()) :: String.t() | nil
  def person_ref(%Entry{actor_kind: :user, source_kind: source, actor_ref: actor})
      when is_binary(source) and source != "" and is_binary(actor) and actor != "",
      do: "#{source}:user:#{actor}"

  def person_ref(_entry), do: nil

  defp fact(nil), do: {:ok, nil}

  # Counted in code points, as the database and the answer's JSON Schema
  # count it: "é" written as e and an accent is one letter and two.
  defp fact(fact) when is_binary(fact) do
    fact = String.trim(fact)

    if String.valid?(fact) and fact != "" and length(String.codepoints(fact)) <= @maximum_fact and
         not String.contains?(fact, <<0>>),
       do: {:ok, fact},
       else: :error
  end

  defp fact(_fact), do: :error

  # One pass at a time per person, taken in the order the items are sorted. A
  # fact not kept yet has no row to lock, so two passes both inserted it and
  # the later crashed on the unique index, and both counted the cap before
  # either wrote (2026-10-04 review).
  defp keep(%{entry: entry, person: person, key: key, fact: fact}, now) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "person-facts:" <> person
    ])

    existing =
      person
      |> PersonFactQuery.by_person()
      |> PersonFactQuery.by_keys([key, forgotten_key(person, key)])
      |> PersonFactQuery.lock_for_update()
      |> Repo.one()

    case change(existing, entry, fact, person) do
      :none -> :ok
      :forget -> forget!(existing, entry, now)
      :say -> said!(existing, entry, fact, key, now)
      :insert -> insert!(person, key, fact, entry)
    end
  end

  defp change(existing, entry, fact, person) do
    cond do
      existing && not newer?(entry, existing) -> :none
      is_nil(fact) -> forgetting(existing)
      existing -> :say
      kept_count(person) >= @maximum_kept -> :none
      true -> :insert
    end
  end

  # Taking back what is not kept changes nothing.
  defp forgetting(%PersonFact{status: :kept}), do: :forget
  defp forgetting(_nothing_kept), do: :none

  # A statement older than the one kept, or than the moment it was forgotten,
  # or from the very message it was forgotten from, changes nothing.
  defp newer?(entry, %PersonFact{status: :forgotten} = existing) do
    since = Enum.max([existing.said_at, existing.forgotten_at], DateTime)

    entry.native_input_id != existing.source_message_ref and
      DateTime.compare(entry.occurred_at, since) == :gt
  end

  defp newer?(entry, %PersonFact{} = existing),
    do: DateTime.compare(entry.occurred_at, existing.said_at) != :lt

  defp kept_count(person) do
    person
    |> PersonFactQuery.by_person()
    |> PersonFactQuery.kept()
    |> Repo.aggregate(:count)
  end

  defp insert!(person, key, fact, entry) do
    Repo.insert!(%PersonFact{
      id: Ecto.UUID.generate(),
      person_ref: person,
      key: key,
      fact: fact,
      status: :kept,
      source_input_id: entry.id,
      source_message_ref: entry.native_input_id,
      conversation_ref: entry.destination_conversation_ref,
      private: private?(entry.destination_conversation_ref),
      said_at: entry.occurred_at
    })

    :ok
  end

  defp said!(existing, entry, fact, key, now) do
    existing
    |> Ecto.Changeset.change(
      key: key,
      fact: fact,
      status: :kept,
      forgotten_at: nil,
      source_input_id: entry.id,
      source_message_ref: entry.native_input_id,
      conversation_ref: entry.destination_conversation_ref,
      private: private?(entry.destination_conversation_ref),
      said_at: entry.occurred_at,
      updated_at: now
    )
    |> Repo.update!()

    :ok
  end

  defp forget!(existing, entry, now) do
    existing
    |> Ecto.Changeset.change(
      key: forgotten_key(existing.person_ref, existing.key),
      fact: nil,
      status: :forgotten,
      forgotten_at: now,
      source_input_id: entry.id,
      source_message_ref: entry.native_input_id,
      said_at: entry.occurred_at,
      updated_at: now
    )
    |> Repo.update!()

    :ok
  end

  # Said in a Slack channel anyone in the workspace can read, a fact may be
  # used wherever that person asks. Said anywhere else, only there: a direct
  # message, a private channel, a channel shared with another organisation,
  # a pull request that may be in a private repository, or Chat.
  defp private?("slack:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [workspace, channel] ->
        not (workspace
             |> ChannelMembershipQuery.by_channel(channel)
             |> ChannelMembershipQuery.joined_public()
             |> Repo.exists?())

      _other ->
        true
    end
  end

  defp private?(_conversation_ref), do: true

  @doc """
  What `person_ref` said about themselves that may be used in
  `conversation_ref`, as sentences in a stable order, or [] for nobody.
  """
  @spec about(String.t() | nil, String.t() | nil) :: [String.t()]
  def about(person_ref, conversation_ref)
      when is_binary(person_ref) and person_ref != "" do
    person_ref
    |> usable(conversation_ref)
    |> PersonFactQuery.select_facts()
    |> Repo.all()
  end

  def about(_person_ref, _conversation_ref), do: []

  @doc """
  What routing and Work read about the person asking, with how to use it, or
  nil when Ryker knows nothing about them there.
  """
  @spec model_context([String.t()]) :: map() | nil
  def model_context([]), do: nil

  def model_context(facts) when is_list(facts),
    do: %{"said_about_themselves" => facts, "use" => @use}

  @doc "Whether `facts` is what `about/2` could have returned, for a restored snapshot."
  @spec valid_facts?(term()) :: boolean()
  def valid_facts?(facts) do
    is_list(facts) and length(facts) in 1..@maximum_recalled and
      Enum.all?(facts, &(is_binary(&1) and String.length(&1) in 1..@maximum_fact))
  end

  @doc """
  What Ryker already knows about the people who wrote `entries`, for the
  learning pass that reads them: it keeps kinds it already has and can take
  one back. Only what may be used in their conversation.
  """
  @spec known_about_authors([Entry.t()]) :: [map()]
  def known_about_authors([%Entry{destination_conversation_ref: conversation} | _] = entries) do
    entries
    |> Enum.flat_map(fn entry ->
      case person_ref(entry) do
        nil -> []
        person -> [{person, %{"kind" => "user", "ref" => entry.actor_ref}}]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map_reduce(@maximum_known, fn {person, actor}, left ->
      facts =
        person
        |> usable(conversation)
        |> PersonFactQuery.select_keyed_facts()
        |> Repo.all()
        |> Enum.take(left)

      {{actor, facts}, left - length(facts)}
    end)
    |> elem(0)
    |> Enum.flat_map(fn
      {_actor, []} -> []
      {actor, facts} -> [%{"actor" => actor, "facts" => facts}]
    end)
  end

  def known_about_authors(_entries), do: []

  defp usable(person_ref, conversation_ref) do
    person_ref
    |> PersonFactQuery.by_person()
    |> PersonFactQuery.kept()
    |> PersonFactQuery.usable_in(conversation_ref)
    |> PersonFactQuery.ordered_by_key()
    |> PersonFactQuery.limit_to(@maximum_recalled)
  end

  @doc """
  Everyone Ryker knows something about, most recently heard first, with one
  place they said something, which names the workspace they belong to.
  """
  @spec people() :: [
          %{
            person_ref: String.t(),
            facts: pos_integer(),
            last_said_at: DateTime.t(),
            conversation_ref: String.t()
          }
        ]
  def people, do: Repo.all(PersonFactQuery.people())

  @doc "One thing Ryker learned about someone, kept or forgotten, or nil."
  @spec get_fact(Ecto.UUID.t()) :: PersonFact.t() | nil
  def get_fact(id) when is_binary(id), do: Repo.one(PersonFactQuery.by_id(id))

  @doc "What Ryker knows about one person, by kind."
  @spec facts(String.t()) :: [PersonFact.t()]
  def facts(person_ref) when is_binary(person_ref) do
    person_ref
    |> PersonFactQuery.by_person()
    |> PersonFactQuery.kept()
    |> PersonFactQuery.ordered_by_key()
    |> Repo.all()
  end

  @doc """
  Forgets everything Ryker learned about one person. Anything they said
  before now never brings it back; what they say later is learned again.
  """
  @spec forget_person(String.t()) :: {:ok, non_neg_integer()}
  def forget_person(person_ref) when is_binary(person_ref) do
    Repo.transaction(fn ->
      forget_where(PersonFactQuery.by_person(person_ref))
    end)
  end

  @doc """
  Forgets one thing Ryker knows about a person. As when the whole person is
  forgotten, nothing said before brings it back; saying it again later does.
  """
  @spec forget_fact(Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def forget_fact(fact_id) when is_binary(fact_id) do
    case Ecto.UUID.cast(fact_id) do
      {:ok, id} -> Repo.transaction(fn -> forget_where(PersonFactQuery.by_id(id)) end)
      :error -> {:ok, 0}
    end
  end

  @doc "Forgets what one message taught, when its author edits or deletes it."
  @spec forget_message_in_transaction(String.t() | nil) :: :ok
  def forget_message_in_transaction(message_ref) when is_binary(message_ref) do
    forget_where(PersonFactQuery.by_source_message(message_ref))
    :ok
  end

  def forget_message_in_transaction(_message_ref), do: :ok

  @doc "Forgets what was said in a conversation that is gone."
  @spec forget_conversation_in_transaction(String.t()) :: :ok
  def forget_conversation_in_transaction(conversation_ref) when is_binary(conversation_ref) do
    forget_where(PersonFactQuery.by_conversation(conversation_ref))
    :ok
  end

  defp forget_where(facts) do
    now = Repo.now!()

    {count, _rows} =
      facts
      |> PersonFactQuery.kept()
      |> PersonFactQuery.forget_at(now)
      |> Repo.update_all([])

    count
  end

  # A forgotten fact keeps a digest of its kind in place of the kind:
  # "medical-leave" said what was forgotten (2026-10-04 review). The digest
  # still finds the row, so nothing said before the forgetting teaches it
  # again. `forget_where/1` computes the same digest in SQL.
  defp forgotten_key(person, key) do
    digest = Crypto.sha256_hex(person <> "\n" <> key)
    "f" <> binary_part(digest, 0, 47)
  end
end
