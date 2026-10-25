defmodule Ryker.People.FactSnapshot do
  @moduledoc "Content-free source receipts for personal facts disclosed to a model."
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.People
  alias Ryker.People.PersonFact
  alias Ryker.Repo
  alias Ryker.Slack

  @doc "Resolve the exact offered sentences against current facts for the authoritative asker."
  def authorize([], _person, _conversation), do: {:ok, %{}}

  def authorize(facts, person, conversation) when is_binary(person) and is_binary(conversation) do
    case Repo.transaction(fn -> resolve(facts, person, conversation) end) do
      {:ok, result} -> result
      _ -> :error
    end
  end

  def authorize(_facts, _person, _conversation), do: :error

  @doc "Recheck exact keyed profiles from a learning prompt against its actual input authors."
  def authorize_authors(documents, entries)
      when is_list(documents) and length(documents) <= 16 and is_list(entries) do
    # Acceptance can update these rows later in the same transaction. Take all
    # authors in the writer's order before any SHARE lock, including authors
    # without a saved profile, so two channels cannot deadlock upgrading facts.
    case Repo.transaction(fn ->
           :ok = People.lock_authors_in_transaction(entries)
           authorize_authors_locked(documents, entries)
         end) do
      {:ok, result} -> result
      _ -> :error
    end
  end

  def authorize_authors(_documents, _entries), do: :error

  defp authorize_authors_locked(documents, entries) do
    Enum.reduce_while(documents, :ok, fn document, :ok ->
      case authorize_author(document, entries) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp authorize_author(
         %{"actor" => %{"kind" => "user", "ref" => ref} = actor, "facts" => facts} = document,
         entries
       )
       when map_size(document) == 2 and map_size(actor) == 2 do
    scopes = entries |> Enum.flat_map(&author_scope(&1, ref)) |> Enum.uniq()

    case scopes do
      [{person, conversation}] -> authorize_keyed(facts, person, conversation)
      _ -> :error
    end
  end

  defp authorize_author(_document, _entries), do: :error

  defp author_scope(
         %Ingress.Inbox.Entry{source_kind: source, actor_kind: :user, actor_ref: ref} = entry,
         ref
       )
       when is_binary(source) and source != "" and is_binary(ref) and ref != "" do
    [{People.person_ref(entry), entry.destination_conversation_ref}]
  end

  defp author_scope(_entry, _ref), do: []

  defp authorize_keyed(facts, person, conversation)
       when is_list(facts) and length(facts) in 1..12 do
    if Enum.all?(facts, &keyed_fact?/1) do
      sentences = Enum.map(facts, & &1["fact"])

      with {:ok, receipts} <- resolve(sentences, person, conversation),
           true <- current_keys?(receipts, facts) do
        :ok
      else
        {:error, :work_derived_context_busy} -> {:error, :work_derived_context_busy}
        _ -> :error
      end
    else
      :error
    end
  end

  defp authorize_keyed(_facts, _person, _conversation), do: :error

  defp keyed_fact?(%{"key" => key, "fact" => fact} = document) when map_size(document) == 2,
    do: is_binary(key) and is_binary(fact)

  defp keyed_fact?(_document), do: false

  defp current_keys?(receipts, facts) do
    ids = Map.keys(receipts)
    # resolve/3 already holds these rows shared. Matching keys too prevents a
    # different kind with identical wording from authorizing the old profile.
    current =
      ids
      |> PersonFact.Query.by_ids()
      |> PersonFact.Query.select_keyed_facts()
      |> Repo.all()
      |> MapSet.new()

    Enum.all?(facts, &MapSet.member?(current, &1))
  end

  defp resolve(facts, person, conversation) do
    if People.valid_facts?(facts) do
      resolve_valid(facts, person, conversation)
    else
      :error
    end
  end

  defp resolve_valid(facts, person, conversation) do
    rows =
      person
      |> PersonFact.Query.by_person()
      |> PersonFact.Query.kept()
      |> PersonFact.Query.usable_in(conversation)
      |> PersonFact.Query.by_facts(facts)
      |> Repo.all()

    receipts = Map.new(rows, &{&1.id, digest(&1)})
    sentences = MapSet.new(rows, & &1.fact)

    with true <- Enum.all?(facts, &MapSet.member?(sentences, &1)),
         :ok <- authorize_receipts(receipts, person, conversation) do
      {:ok, receipts}
    else
      {:error, :work_derived_context_busy} -> {:error, :work_derived_context_busy}
      _ -> :error
    end
  end

  @doc "Recheck retained facts, including their current source visibility, inside the owning transaction."
  def authorize_receipts(entries, person, conversation)
      when is_map(entries) and is_binary(person) and is_binary(conversation) do
    if map_size(entries) == 0 do
      :ok
    else
      authorize_nonempty(entries, person, conversation)
    end
  end

  def authorize_receipts(entries, _person, _conversation) when entries == %{}, do: :ok
  def authorize_receipts(_entries, _person, _conversation), do: :error

  defp authorize_nonempty(entries, person, conversation) do
    ids = Map.keys(entries)
    query = PersonFact.Query.by_ids(ids)
    origins = Repo.all(query)

    # Channel deletion takes its fence before forgetting PersonFact rows. Read
    # origins without row locks, fence them, then verify the locked row still
    # matches the same receipt. A moved source cannot bypass its own fence.
    with true <- length(origins) == map_size(entries),
         :ok <- fence(conversation),
         true <- Enum.all?(origins, &visible?(&1, person, conversation)),
         :ok <- lock_and_check(query, entries, origins) do
      :ok
    else
      {:error, :work_derived_context_busy} -> {:error, :work_derived_context_busy}
      _ -> :error
    end
  end

  defp lock_and_check(query, entries, origins) do
    rows =
      query
      |> PersonFact.Query.ordered_by_key()
      |> PersonFact.Query.lock_for_share_skip_locked()
      |> Repo.all()

    cond do
      length(rows) != length(origins) -> {:error, :work_derived_context_busy}
      Enum.all?(rows, &(entries[&1.id] == digest(&1) and &1.status == :kept)) -> :ok
      true -> :error
    end
  end

  defp visible?(%PersonFact{person_ref: person, status: :kept} = fact, person, conversation) do
    same = fact.conversation_ref == conversation
    source = fact.conversation_ref

    same or
      (not fact.private and same_workspace?(source, conversation) and
         Slack.ChannelFence.authorize_public_in_transaction("slack", source) == :ok)
  end

  defp visible?(_fact, _person, _conversation), do: false

  defp same_workspace?(source, destination) do
    Episodes.Scope.workspace_ref("slack", source) ==
      Episodes.Scope.workspace_ref("slack", destination)
  end

  defp fence("slack:" <> _ = conversation),
    do: Slack.ChannelFence.authorize_in_transaction("slack", conversation)

  defp fence(_conversation), do: :ok

  defp digest(%PersonFact{} = fact) do
    fact
    |> Map.take([
      :id,
      :person_ref,
      :key,
      :fact,
      :source_input_id,
      :source_message_ref,
      :conversation_ref,
      :private,
      :said_at
    ])
    |> Map.update!(:said_at, &DateTime.to_iso8601/1)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> CanonicalJSON.digest()
  end

  defp digest(_fact), do: nil
end
