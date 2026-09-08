defmodule Responder.State.MemorySearch do
  @moduledoc "Bounded, permission-rechecked keyset recall across existing memory owners."
  import Ecto.Query
  alias Responder.{CanonicalJSON, Repo}
  alias Responder.Episodes.{Episode, Event}

  alias Responder.State.{
    Behaviors,
    Continuity,
    Knowledge,
    KnowledgeSnapshot,
    Memories,
    MemorySearchPage,
    Observations
  }

  alias Responder.Work.{Session, Turn}

  @continuity ~w(knowledge observation summary rollup)
  @maximum_bytes 65_536
  @maximum_visits 64
  @cursor_lifetime 3600
  @budget_errors [
    :query_canceled,
    :lock_not_available,
    :deadlock_detected,
    :serialization_failure
  ]

  def search(binding, arguments, secret) when is_binary(secret) and byte_size(secret) >= 16 do
    Repo.transaction(fn -> search_in_transaction(binding, arguments, secret) end)
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in @budget_errors,
        do: {:error, :memory_search_budget_exceeded},
        else: reraise(error, __STACKTRACE__)
  end

  def search(_, _, _), do: {:error, :not_configured}

  defp search_in_transaction(binding, arguments, secret) do
    # Result count is not a database-work bound. A broad literal search or
    # expensive lineage filter must fail explicitly, not occupy a worker forever.
    Repo.query!("SET LOCAL statement_timeout = '5000ms'")
    Repo.query!("SET LOCAL lock_timeout = '1000ms'")
    binding = lock_binding(binding, arguments)

    {page, state} =
      case restore(binding, arguments, secret) do
        {:ok, page, state} -> {page, state}
        {:error, reason} -> Repo.rollback(reason)
      end

    # Work acceptance and source exposure lock the session before channel
    # authorization. Take that same subsequence before any recall accounting,
    # irrespective of which result kind resumes first on this cursor page.
    case Observations.locked_scope(binding.episode, binding.session.repository_ref) do
      {:ok, _scope} -> :ok
      {:error, reason} -> Repo.rollback(search_error(reason))
    end

    fetch = fn lane, current -> fetch(lane, binding, current) end
    {documents, state} = collect(page, state, arguments["limit"], fetch)

    case KnowledgeSnapshot.expose(binding, documents) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(search_error(reason))
    end

    exhausted = exhausted?(state)
    cursor = if not exhausted, do: seal(cursor_document(binding, arguments, page, state), secret)

    %{
      "memories" => documents,
      "cursor" => cursor,
      "exhausted" => exhausted,
      "time_basis" => page.time_basis
    }
  end

  defp lock_binding(binding, arguments) do
    session =
      Repo.one(
        from(s in Session,
          where: s.id == ^binding.session.id and s.episode_id == ^binding.episode.id,
          lock: "FOR UPDATE NOWAIT"
        )
      )

    with %Session{cleanup_status: :active} <- session,
         true <-
           same_fields?(session, binding.session, [
             :episode_id,
             :generation,
             :repository_ref,
             :coop_session_id,
             :authority_digest,
             :policy_digest
           ]),
         true <- is_binary(binding.turn.lease_ref),
         {episode, turn} <-
           Repo.one(
             from(e in Episode,
               join: t in Turn,
               on: t.episode_id == e.id,
               where:
                 e.id == ^binding.episode.id and t.id == ^binding.turn.id and
                   t.session_id == ^session.id,
               where: e.state == :working and e.owner_kind == :turn and e.owner_ref == t.turn_ref,
               where:
                 t.status == :pending and t.lease_ref == ^binding.turn.lease_ref and
                   t.lease_expires_at > fragment("clock_timestamp()"),
               select: {e, t}
             )
           ),
         true <-
           same_fields?(episode, binding.episode, [
             :destination_transport,
             :destination_conversation_ref,
             :destination_thread_ref,
             :execution_mode
           ]) do
      Map.merge(binding, %{
        episode: episode,
        session: session,
        turn: turn,
        operator_ref: latest_operator_ref(episode)
      })
    else
      _ ->
        Repo.rollback(
          if arguments["cursor"],
            do: :invalid_memory_cursor,
            else: :state_tools_binding_not_authorized
        )
    end
  end

  defp same_fields?(left, right, fields), do: Map.take(left, fields) == Map.take(right, fields)

  # ChannelFence deliberately uses non-bang queries; preserve its SQL failure
  # before another query runs in the aborted transaction and hides the cause.
  defp search_error(%Postgrex.Error{postgres: %{code: code}}) when code in @budget_errors,
    do: :memory_search_budget_exceeded

  defp search_error({:store_failed, :configuration_lock, reason}), do: search_error(reason)
  defp search_error(reason), do: reason

  @doc false
  def continuity(episode, repository, query, scope, limit) do
    binding = %{episode: episode, session: %{repository_ref: repository}}
    page = MemorySearchPage.first(query, scope)

    {documents, _state} =
      collect(page, initial(["continuity"]), limit, fn lane, current ->
        fetch(lane, binding, current)
      end)

    documents
  end

  defp initial(kinds) do
    kinds = Enum.filter(~w(fact guidance continuity), &(&1 in kinds))

    lanes =
      Enum.flat_map(kinds, fn
        "continuity" -> @continuity
        kind -> [kind]
      end)

    %{
      "kinds" => kinds,
      "positions" => Map.new(lanes, &{&1, nil}),
      "kind_index" => 0,
      "continuity_index" => 0
    }
  end

  defp collect(page, state, limit, fetch), do: collect(page, state, limit, fetch, {[], 0, 0})

  defp collect(_page, state, 0, _fetch, {documents, _bytes, _visits}),
    do: {Enum.reverse(documents), state}

  defp collect(_page, state, _limit, _fetch, {documents, _bytes, @maximum_visits}),
    do: {Enum.reverse(documents), state}

  defp collect(page, state, limit, fetch, {documents, _bytes, _visits} = progress) do
    case next_lane(state) do
      nil ->
        {Enum.reverse(documents), state}

      {lane, next} ->
        collect_lane(page, {state, lane, next}, limit, fetch, progress)
    end
  end

  defp collect_lane(page, {state, lane, next} = selection, limit, fetch, progress) do
    {documents, bytes, visits} = progress
    current = %{page | position: state["positions"][lane]}

    case fetch.(lane, current) do
      :done ->
        collect(
          page,
          put_in(next, ["positions", lane], "done"),
          limit,
          fetch,
          {documents, bytes, visits + 1}
        )

      {:skip, position} ->
        collect(
          page,
          put_in(next, ["positions", lane], position),
          limit,
          fetch,
          {documents, bytes, visits + 1}
        )

      {:ok, document, position} ->
        collect_document(page, selection, limit, fetch, progress, document, position)
    end
  end

  defp collect_document(page, {state, lane, next}, limit, fetch, progress, document, position) do
    {documents, bytes, visits} = progress
    size = byte_size(CanonicalJSON.encode!(document)) + 1

    cond do
      size > @maximum_bytes ->
        Repo.rollback(:memory_search_result_too_large)

      bytes + size > @maximum_bytes ->
        {Enum.reverse(documents), state}

      true ->
        collect(
          page,
          put_in(next, ["positions", lane], position),
          limit - 1,
          fetch,
          {[document | documents], bytes + size, visits + 1}
        )
    end
  end

  defp exhausted?(state),
    do: Enum.all?(state["positions"], fn {_lane, position} -> position == "done" end)

  defp next_lane(state) do
    kinds = state["kinds"]
    Enum.find_value(0..(length(kinds) - 1), &next_kind_lane(state, kinds, &1))
  end

  defp next_kind_lane(state, kinds, offset) do
    index = rem(state["kind_index"] + offset, length(kinds))
    next = %{state | "kind_index" => rem(index + 1, length(kinds))}

    case Enum.at(kinds, index) do
      "continuity" -> next_continuity_lane(next)
      lane -> if state["positions"][lane] != "done", do: {lane, next}
    end
  end

  defp next_continuity_lane(state) do
    Enum.find_value(0..(length(@continuity) - 1), fn offset ->
      index = rem(state["continuity_index"] + offset, length(@continuity))
      lane = Enum.at(@continuity, index)

      if state["positions"][lane] != "done",
        do: {lane, %{state | "continuity_index" => rem(index + 1, length(@continuity))}}
    end)
  end

  defp fetch("fact", binding, page), do: Memories.search_page(context(binding), page)

  defp fetch("guidance", binding, page) do
    context = context(binding) |> Map.put(:operator_ref, binding.operator_ref)
    Behaviors.search_page(context, page)
  end

  defp fetch("knowledge", binding, page),
    do: Knowledge.search_page(binding.episode, binding.session.repository_ref, page)

  defp fetch("observation", binding, page),
    do: Observations.search_page(binding.episode, binding.session.repository_ref, page)

  defp fetch("summary", binding, page),
    do: Continuity.search_page(:summary, binding.episode, binding.session.repository_ref, page)

  defp fetch("rollup", binding, page),
    do: Continuity.search_page(:rollup, binding.episode, binding.session.repository_ref, page)

  defp context(binding) do
    episode = binding.episode
    ref = episode.destination_conversation_ref

    workspace =
      case {episode.destination_transport, String.split(ref, ":", parts: 3)} do
        {"slack", ["slack", id, _]} -> "slack:#{id}"
        {"github", ["github", id, _]} -> "github:#{id}"
        _ -> ref
      end

    %{conversation_ref: ref, repository: binding.session.repository_ref, workspace_ref: workspace}
  end

  defp latest_operator_ref(episode) do
    Repo.one(
      from(e in Event,
        where:
          e.episode_id == ^episode.id and e.kind == :input_admitted and
            e.dedupe_key in ^episode.active_input_refs,
        order_by: [desc: e.sequence],
        limit: 1,
        select: fragment("?::jsonb ->> 'actor_ref'", e.payload)
      )
    )
  end

  defp restore(binding, arguments, secret) do
    with {:ok, after_at} <- date(arguments["after"]),
         {:ok, before_at} <- date(arguments["before"]),
         true <- is_nil(after_at) or is_nil(before_at) or DateTime.before?(after_at, before_at) do
      page = %{
        MemorySearchPage.first(arguments["query"], arguments["scope"])
        | after: after_at,
          before: before_at,
          time_basis: arguments["time_basis"]
      }

      restore_cursor(arguments["cursor"], binding, arguments, secret, page)
    else
      _ -> {:error, :invalid_memory_time_filter}
    end
  end

  defp restore_cursor(nil, _binding, arguments, _secret, page),
    do: {:ok, page, initial(arguments["kinds"])}

  defp restore_cursor(cursor, binding, arguments, secret, page) do
    with {:ok, document} <- unseal(cursor, secret),
         true <- document["query"] == query_fingerprint(binding, arguments),
         {:ok, cutoff} <- date(document["cutoff"]),
         true <-
           is_struct(cutoff, DateTime) and
             DateTime.diff(page.cutoff, cutoff) in 0..@cursor_lifetime,
         %{"kinds" => kinds} = state <- document["state"],
         true <- kinds == initial(arguments["kinds"])["kinds"] do
      {:ok, %{page | cutoff: cutoff}, state}
    else
      _ -> {:error, :invalid_memory_cursor}
    end
  end

  defp date(nil), do: {:ok, nil}

  defp date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, 0} -> {:ok, date}
      _ -> :error
    end
  end

  defp date(_), do: :error

  defp query_fingerprint(binding, arguments) do
    CanonicalJSON.digest(%{
      "query" => String.trim(arguments["query"]),
      "scope" => arguments["scope"],
      "kinds" => Enum.sort(Enum.uniq(arguments["kinds"])),
      "after" => arguments["after"],
      "before" => arguments["before"],
      "time_basis" => arguments["time_basis"],
      "episode" => binding.episode.id,
      "session" => binding.session.id,
      "transport" => binding.episode.destination_transport,
      "conversation" => binding.episode.destination_conversation_ref,
      "thread" => binding.episode.destination_thread_ref,
      "execution_mode" => Atom.to_string(binding.episode.execution_mode),
      "turn" => binding.turn.id,
      "lease" => binding.turn.lease_ref,
      "repository" => binding.session.repository_ref,
      "operator" => binding.operator_ref,
      "session_generation" => binding.session.generation,
      "coop_session" => binding.session.coop_session_id
    })
  end

  defp cursor_document(binding, arguments, page, state),
    do: %{
      "version" => 1,
      "query" => query_fingerprint(binding, arguments),
      "cutoff" => DateTime.to_iso8601(page.cutoff),
      "state" => state
    }

  defp seal(document, secret) do
    body = document |> CanonicalJSON.encode!() |> Base.url_encode64(padding: false)

    signature =
      :crypto.mac(:hmac, :sha256, secret, "memory-search:" <> body)
      |> Base.url_encode64(padding: false)

    body <> "." <> signature
  end

  defp unseal(cursor, secret) when is_binary(cursor) and byte_size(cursor) <= 4096 do
    with [body, signature] <- String.split(cursor, ".", parts: 2),
         expected =
           :crypto.mac(:hmac, :sha256, secret, "memory-search:" <> body)
           |> Base.url_encode64(padding: false),
         true <-
           byte_size(signature) == byte_size(expected) and
             Plug.Crypto.secure_compare(signature, expected),
         {:ok, json} <- Base.url_decode64(body, padding: false),
         {:ok, %{"version" => 1} = document} <- Jason.decode(json),
         do: {:ok, document},
         else: (_ -> :error)
  end

  defp unseal(_, _), do: :error
end
