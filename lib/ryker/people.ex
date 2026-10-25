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
  words and records content-free withdrawal boundaries separately from the
  current facts, so a changed fact label or a later statement cannot make a
  withdrawn source teach them again. Nothing said before an explicit forget
  refreshes the profile. Identical kept sentences under other labels are
  forgotten together; already-kept different facts remain intact. They
  are kept until forgotten: a birthday is worth remembering for more than
  the ninety days conversation memory keeps.
  """
  alias Ryker.AdvisoryLock
  alias Ryker.ConversationRef
  alias Ryker.Crypto
  alias Ryker.Ingress
  alias Ryker.People.{FactWithdrawal, PersonFact}
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Slack

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
  @spec learn_in_transaction([map()], [Ingress.Inbox.Entry.t()]) :: :ok
  def learn_in_transaction(items, entries) when is_list(items) and is_list(entries) do
    by_id = Map.new(entries, &{&1.id, &1})
    statements = Enum.flat_map(items, &statement(&1, by_id))
    :ok = lock_authors_in_transaction(entries)
    now = Repo.now!()

    # A later positive may replace a retraction's key, but never its withdrawal
    # custody. Establish every boundary before any positive can be learned.
    statements
    |> Enum.filter(&is_nil(&1.fact))
    |> Enum.sort_by(&{&1.person, &1.key})
    |> Enum.each(&keep(&1, now))

    statements
    |> Enum.reject(&(is_nil(&1.fact) or withdrawn_source?(&1.person, &1.entry)))
    |> Enum.sort_by(& &1.entry.occurred_at, DateTime)
    |> Enum.reduce(%{}, &Map.put(&2, {&1.person, &1.key}, &1))
    |> Map.values()
    |> Enum.sort_by(&{&1.person, &1.key})
    |> Enum.each(&keep(&1, now))
  end

  @doc """
  Internal — `Ryker.People.FactSnapshot` calls this inside its transaction,
  before learning reads or writes profile rows. Locks every actual input
  author in stable order. Returns `:ok`; raises on a database failure.
  """
  @spec lock_authors_in_transaction([Ingress.Inbox.Entry.t()]) :: :ok
  def lock_authors_in_transaction(entries) when is_list(entries) do
    entries
    |> Enum.map(&person_ref/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(&lock_person!/1)
  end

  defp statement(%{"source_input_id" => id, "key" => key, "fact" => fact} = item, by_id)
       when map_size(item) == 3 do
    with %Ingress.Inbox.Entry{} = entry <- by_id[id],
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
  @spec person_ref(Ingress.Inbox.Entry.t()) :: String.t() | nil
  def person_ref(%Ingress.Inbox.Entry{actor_kind: :user, source_kind: source, actor_ref: actor})
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
  defp keep(%{entry: entry, person: person, fact: fact} = statement, now) do
    lock_person!(person)
    if is_nil(fact), do: withdraw!(person, entry, now)

    if is_nil(fact) or not withdrawn_source?(person, entry),
      do: keep_current(statement, now),
      else: :ok
  end

  defp keep_current(%{entry: entry, person: person, key: key, fact: fact}, now) do
    query =
      person
      |> PersonFact.Query.by_person()
      |> PersonFact.Query.by_keys([key, forgotten_key(person, key)])

    # Retraction uses the row only as a content hint. Locking this selected
    # row before its copies would invert source withdrawal's stable row order.
    query = if is_nil(fact), do: query, else: PersonFact.Query.lock_for_update(query)
    existing = Repo.peek(query)

    case change(existing, entry, fact, person) do
      :none -> :ok
      :forget -> forget!(existing, entry, now)
      :say -> said!(existing, entry, fact, key, now)
      :insert -> insert!(person, key, fact, entry)
    end
  end

  defp lock_person!(person) do
    key = "person-facts:" <> person
    AdvisoryLock.hold!(key)
  end

  defp withdrawn_source?(person, %Ingress.Inbox.Entry{
         native_input_id: message,
         occurred_at: occurred_at
       }) do
    person
    |> FactWithdrawal.Query.by_person()
    |> FactWithdrawal.Query.blocking_source(message, occurred_at)
    |> Repo.exists?()
  end

  defp withdrawn_source?(_person, _entry), do: true

  defp change(existing_fact, %Ingress.Inbox.Entry{} = entry, fact, person)
       when is_struct(existing_fact, PersonFact) or is_nil(existing_fact) do
    cond do
      is_nil(fact) -> forgetting(existing_fact)
      existing_fact && not newer?(entry, existing_fact) -> :none
      existing_fact -> :say
      kept_count(person) >= @maximum_kept -> :none
      true -> :insert
    end
  end

  defp change(_existing_fact, _entry, _fact, _person), do: :none

  # Every retraction already has a withdrawal boundary; only a kept row
  # needs its words erased.
  defp forgetting(%PersonFact{status: :kept}), do: :forget
  defp forgetting(_nothing_kept), do: :none

  # Durable withdrawals already reject withdrawn sources and historical inputs.
  # The replaceable row only orders statements; processing time must not block
  # a genuine statement made after a learned retraction in the same batch.
  defp newer?(%Ingress.Inbox.Entry{} = entry, %PersonFact{} = existing_fact),
    do: DateTime.compare(entry.occurred_at, existing_fact.said_at) != :lt

  defp newer?(_entry, _existing_fact), do: false

  defp kept_count(person) do
    person
    |> PersonFact.Query.by_person()
    |> PersonFact.Query.kept()
    |> Repo.aggregate(:count)
  end

  defp insert!(person, key, fact, entry) do
    Repo.insert!(%PersonFact{
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

  # A valid retraction matters even before its old positive statement has
  # been learned. Preserve it before looking for a replaceable current row.
  defp withdraw!(person, %Ingress.Inbox.Entry{} = entry, %DateTime{} = now) do
    record_withdrawals(
      [{person, nil}, {person, entry.native_input_id}],
      entry.occurred_at,
      now
    )
  end

  defp withdraw!(_person, _entry, _now),
    do: Repo.rollback({:invalid_person_fact_retraction, :entry})

  defp forget!(%PersonFact{} = existing_fact, %Ingress.Inbox.Entry{} = entry, %DateTime{} = now) do
    query =
      existing_fact.person_ref
      |> PersonFact.Query.by_person()
      |> PersonFact.Query.by_facts([existing_fact.fact])
      |> PersonFact.Query.said_at_or_before(entry.occurred_at)

    forget_where(query, now)
    :ok
  end

  defp forget!(_existing_fact, _entry, _now),
    do: Repo.rollback({:invalid_person_fact_retraction, :entry})

  # Said in a Slack channel anyone in the workspace can read, a fact may be
  # used wherever that person asks. Said anywhere else, only there: a direct
  # message, a private channel, a channel shared with another organisation,
  # a pull request that may be in a private repository, or Chat.
  defp private?("slack:" <> _rest = conversation_ref) do
    case ConversationRef.parse_slack(conversation_ref) do
      {:ok, workspace, channel} ->
        not (workspace
             |> Slack.ChannelMembership.Query.by_channel(channel)
             |> Slack.ChannelMembership.Query.joined_public()
             |> Repo.exists?())

      :error ->
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
    |> PersonFact.Query.select_facts()
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
  @spec known_about_authors([Ingress.Inbox.Entry.t()]) :: [map()]
  def known_about_authors(
        [%Ingress.Inbox.Entry{destination_conversation_ref: conversation} | _] = entries
      ) do
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
        |> PersonFact.Query.select_keyed_facts()
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
    |> PersonFact.Query.by_person()
    |> PersonFact.Query.kept()
    |> PersonFact.Query.usable_in(conversation_ref)
    |> PersonFact.Query.ordered_by_key()
    |> PersonFact.Query.limit_to(@maximum_recalled)
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
  def people, do: Repo.all(PersonFact.Query.people())

  @doc "One thing Ryker learned about someone, kept or forgotten."
  @spec fetch_fact(Ecto.UUID.t()) :: {:ok, PersonFact.t()} | {:error, :not_found}
  def fetch_fact(id) when is_binary(id), do: Repo.fetch(PersonFact.Query.by_id(id))

  @doc "What Ryker knows about one person, by kind."
  @spec facts(String.t()) :: [PersonFact.t()]
  def facts(person_ref) when is_binary(person_ref) do
    person_ref
    |> PersonFact.Query.by_person()
    |> PersonFact.Query.kept()
    |> PersonFact.Query.ordered_by_key()
    |> Repo.all()
  end

  @doc """
  Forgets everything Ryker learned about one person. Anything they said
  before now never brings it back; what they say later is learned again.
  Returns `{:ok, count}`, including zero; an invalid person reference returns
  `{:error, {:invalid_person_forgetting, :person_ref}}` without writing.
  """
  @spec forget_person(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def forget_person(person_ref) when is_binary(person_ref) do
    if Reference.text?(person_ref, 1024, 4096) do
      Repo.transaction(fn ->
        lock_person!(person_ref)
        now = Repo.now!()
        query = PersonFact.Query.by_person(person_ref)
        {count, sources} = forget_where(query, now)
        boundary = cutoff(sources, now)
        record_withdrawals([{person_ref, nil}], boundary, now)
        count
      end)
    else
      {:error, {:invalid_person_forgetting, :person_ref}}
    end
  end

  @doc """
  Forgets one thing Ryker knows about a person. As when the whole person is
  forgotten, nothing said before brings it back; saying it again later does.
  Existing identical sentences under other kinds are forgotten together.
  """
  @spec forget_fact(Ecto.UUID.t()) :: {:ok, non_neg_integer()}
  def forget_fact(fact_id) when is_binary(fact_id) do
    case Ecto.UUID.cast(fact_id) do
      {:ok, id} -> Repo.transaction(fn -> forget_one(id) end)
      :error -> {:ok, 0}
    end
  end

  @doc "Forgets what one message taught, when its author edits or deletes it."
  @spec forget_message_in_transaction(String.t() | nil) :: :ok
  def forget_message_in_transaction(message_ref) when is_binary(message_ref) do
    query = PersonFact.Query.by_source_message(message_ref)
    now = Repo.now!()
    forget_where(query, now)
    :ok
  end

  def forget_message_in_transaction(_message_ref), do: :ok

  @doc "Forgets what was said in a conversation that is gone."
  @spec forget_conversation_in_transaction(String.t()) :: :ok
  def forget_conversation_in_transaction(conversation_ref) when is_binary(conversation_ref) do
    query = PersonFact.Query.by_conversation(conversation_ref)
    now = Repo.now!()
    forget_where(query, now)
    :ok
  end

  defp forget_one(id) do
    selected_query = id |> PersonFact.Query.by_id() |> PersonFact.Query.kept()

    # Reread under the person mutex for updated statements, keeping the initial
    # words if source withdrawal erased them while we waited. Lock all actual
    # matches together in their stable order, never the selected row first.
    with {:ok, %PersonFact{person_ref: person} = selected_fact} <- Repo.fetch(selected_query),
         :ok <- lock_person!(person) do
      fact = Repo.peek(selected_query) || selected_fact
      now = Repo.now!()

      query =
        person
        |> PersonFact.Query.by_person()
        |> PersonFact.Query.by_facts([fact.fact])

      {count, sources} = forget_where(query, now)
      boundary = cutoff([fact | sources], now)
      record_withdrawals([{person, nil}], boundary, now)
      count
    else
      {:error, :not_found} -> 0
    end
  end

  defp forget_where(facts, now) do
    # Operator writes and source deletion lock their overlapping rows in the
    # same order. Deletion already owns its source fence; taking person locks
    # here would invert that order against profile authorization.
    sources =
      facts
      |> PersonFact.Query.kept()
      |> PersonFact.Query.ordered_by_person_and_key()
      |> PersonFact.Query.lock_for_update()
      |> Repo.all()

    ids = Enum.map(sources, & &1.id)

    {count, _rows} =
      ids |> PersonFact.Query.by_ids() |> PersonFact.Query.forget_at(now) |> Repo.update_all([])

    withdrawals = Enum.map(sources, &{&1.person_ref, &1.source_message_ref})
    record_withdrawals(withdrawals, now, now)
    {count, sources}
  end

  defp cutoff(sources, now) do
    said_at = Enum.map(sources, & &1.said_at)
    Enum.max([now | said_at], DateTime)
  end

  defp record_withdrawals(sources, boundary, now) do
    sources
    |> Enum.uniq()
    |> Enum.sort_by(fn {person, message} -> {person, message || ""} end)
    |> Enum.map(fn {person, message} ->
      %{
        id: Repo.generate_id(),
        person_ref: person,
        source_message_ref: message,
        withdrawn_at: boundary,
        inserted_at: now,
        updated_at: now
      }
    end)
    |> Enum.chunk_every(1000)
    |> Enum.each(fn rows ->
      conflict = FactWithdrawal.Query.advance()

      Repo.insert_all(FactWithdrawal, rows,
        on_conflict: conflict,
        conflict_target: [:person_ref, :source_message_ref]
      )
    end)
  end

  # A forgotten fact keeps a digest of its kind in place of the kind:
  # "medical-leave" said what was forgotten (2026-10-04 review). The digest
  # still finds the replaceable current row. FactWithdrawal holds the durable
  # replay boundary. `forget_where/2` computes the same kind digest in SQL.
  defp forgotten_key(person, key) do
    digest = Crypto.sha256_hex(person <> "\n" <> key)
    "f" <> binary_part(digest, 0, 47)
  end
end
