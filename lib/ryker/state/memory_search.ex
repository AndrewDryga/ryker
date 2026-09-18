defmodule Ryker.State.MemorySearch do
  @moduledoc "Bounded, permission-rechecked keyset recall across existing memory owners."
  import Ecto.Query
  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.Episodes.Event

  alias Ryker.State.{
    Behaviors,
    Cases,
    Continuity,
    Knowledge,
    KnowledgeSnapshot,
    Memories,
    MemorySearchPage,
    MemorySourceLink,
    Observations,
    Scope
  }

  alias Ryker.StateTools.Binding

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

  @doc "One-hop source-related memory for an already authorized platform lookup. No provider I/O."
  def related(binding, targets, before_time) when is_list(targets) and length(targets) <= 20 do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL statement_timeout = '5000ms'")
      binding = lock_binding(binding, %{"cursor" => nil})
      {:ok, before_at} = date(before_time)

      page =
        MemorySearchPage.first("", "workspace")
        |> Map.put(:source_targets, Enum.uniq(targets))
        |> Map.put(:before, before_at)

      {documents, state, _budget} =
        collect(page, initial(["fact", "guidance", "continuity"]), 8, &fetch(&1, binding, &2))

      case KnowledgeSnapshot.expose(binding, documents) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(search_error(reason))
      end

      %{
        "memories" => Enum.map(documents, &MemorySourceLink.for_caller(&1, binding)),
        "coverage" => %{
          "status" => if(exhausted?(state), do: "complete", else: "partial"),
          "basis" => "direct_source_relationship",
          "limit" => 8,
          "per_source_limit" => 8,
          "before" => before_time,
          "time_basis" => "changed"
        }
      }
    end)
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in @budget_errors,
        do: {:error, :memory_search_budget_exceeded},
        else: reraise(error, __STACKTRACE__)
  end

  defp search_in_transaction(binding, arguments, secret) do
    # Result count is not a database-work bound. A broad literal search or
    # expensive lineage filter must fail explicitly, not occupy a worker forever.
    Repo.query!("SET LOCAL statement_timeout = '5000ms'")
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
    {documents, state, budget} = collect(page, state, arguments["limit"], fetch)
    {related, coverage} = related_to_results(documents, page, binding, budget)

    case KnowledgeSnapshot.expose(binding, documents ++ related) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback(search_error(reason))
    end

    exhausted = exhausted?(state)
    cursor = if not exhausted, do: seal(cursor_document(binding, arguments, page, state), secret)

    %{
      "memories" => Enum.map(documents, &MemorySourceLink.for_caller(&1, binding)),
      "related_memory" => Enum.map(related, &MemorySourceLink.for_caller(&1, binding)),
      "related_memory_coverage" => coverage,
      "cursor" => cursor,
      "exhausted" => exhausted,
      "time_basis" => page.time_basis
    }
  end

  defp related_to_results(documents, page, binding, {bytes, visits}) do
    targets = documents |> Enum.flat_map(&MemorySourceLink.context_targets/1) |> Enum.uniq()

    if targets == [] do
      {[], %{"status" => "unavailable"}}
    else
      related_page =
        %{page | query: "", scope: "workspace", position: nil, after: nil, time_basis: "changed"}
        |> Map.put(:source_targets, Enum.take(targets, 20))
        |> Map.put(:excluded_ids, document_ids(documents))

      {related, state, _budget} =
        collect(
          related_page,
          initial(["fact", "guidance", "continuity"]),
          8,
          &fetch(&1, binding, &2),
          {[], bytes, visits}
        )

      {related,
       %{
         "status" =>
           if(exhausted?(state) and length(targets) <= 20, do: "complete", else: "partial"),
         "basis" => "direct_source_relationship",
         "before" => if(page.before, do: DateTime.to_iso8601(page.before)),
         "time_basis" => "changed",
         "limit" => 8,
         "per_source_limit" => 8
       }}
    end
  end

  defp document_ids(documents) do
    Enum.flat_map(documents, &document_id/1)
  end

  defp document_id(document) do
    ref = document["source_ref"] || document["memory_ref"] || document["behavior_ref"]

    case ref |> String.split(":") |> List.last() |> Ecto.UUID.cast() do
      {:ok, id} -> [id]
      _ -> []
    end
  end

  defp lock_binding(binding, arguments) do
    case Binding.lock_current(binding) do
      {:ok, current} ->
        Map.put(current, :operator_ref, latest_operator_ref(current.episode))

      {:error, _} ->
        Repo.rollback(
          if arguments["cursor"],
            do: :invalid_memory_cursor,
            else: :state_tools_binding_not_authorized
        )
    end
  end

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

    {documents, _state, _budget} =
      collect(page, initial(["continuity"]), limit, fn lane, current ->
        fetch(lane, binding, current)
      end)

    documents
  end

  defp initial(kinds) do
    kinds = Enum.filter(~w(fact guidance continuity case), &(&1 in kinds))

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

  defp collect(page, state, limit, fetch), do: collect(page, state, limit, fetch, {[], 1, 0})

  defp collect(_page, state, 0, _fetch, {documents, bytes, visits}),
    do: {Enum.reverse(documents), state, {bytes, visits}}

  defp collect(_page, state, _limit, _fetch, {documents, bytes, @maximum_visits}),
    do: {Enum.reverse(documents), state, {bytes, @maximum_visits}}

  defp collect(page, state, limit, fetch, {documents, bytes, visits} = progress) do
    case next_lane(state) do
      nil ->
        {Enum.reverse(documents), state, {bytes, visits}}

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
        {Enum.reverse(documents), state, {bytes, visits + 1}}

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

  defp fetch("case", binding, page), do: Cases.search_page(context(binding), page)

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
    %{
      conversation_ref: binding.episode.destination_conversation_ref,
      repository: binding.session.repository_ref,
      workspace_ref: Scope.workspace_ref(binding.episode)
    }
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
