defmodule Ryker.State.Memories.Recall do
  @moduledoc """
  Reads confirmed memory for one exact model context.

  Recall ranks the entries a conversation, repository, and workspace may see;
  search pages through them by relevance. Both charge a recall against the
  exact still-active row that was selected, so a fact the operator revoked or
  edited while the read waited is neither disclosed nor counted.
  """

  import Ecto.Query

  alias Ryker.Episodes.Episode
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.State.{Memories, MemoryEntry, MemorySearchPage, MemorySourceLink, Scope}

  @doc "Returns and accounts for memory visible to one exact model context."
  @spec recall(map(), pos_integer()) :: [map()]
  def recall(context, limit \\ 20)

  def recall(context, limit) when is_map(context) and is_integer(limit) and limit in 1..50 do
    case retrieval_context(context) do
      {:ok, context} -> recall_entries(context, limit)
      {:error, _reason} -> []
    end
  end

  def recall(_context, _limit), do: []

  @spec search(map(), String.t(), String.t(), pos_integer()) :: [map()]
  def search(context, query, scope, limit)
      when is_map(context) and is_binary(query) and is_binary(scope) and is_integer(limit) and
             limit in 1..50 do
    case retrieval_context(context) do
      {:ok, context} ->
        Repo.transaction(fn -> search_locked(context, query, scope, limit) end)
        |> case do
          {:ok, entries} -> entries
          {:error, _reason} -> []
        end

      {:error, _reason} ->
        []
    end
  end

  def search(_context, _query, _scope, _limit), do: []

  @spec model_context(Episode.t(), String.t() | nil) :: [map()]
  def model_context(%Episode{} = episode, repository)
      when is_binary(repository) or is_nil(repository) do
    recall(%{
      conversation_ref: episode.destination_conversation_ref,
      repository: repository,
      workspace_ref: Scope.workspace_ref(episode)
    })
  end

  def model_context(_episode, _repository), do: []

  defp recall_entries(context, limit) do
    Repo.transaction(fn -> recall_locked(context, limit) end)
    |> case do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  defp recall_locked(context, limit) do
    entries =
      context
      |> visible_entries()
      |> Enum.sort_by(&rank/1)
      |> Enum.take(limit)

    account_memory(entries)
  end

  defp search_locked(context, query, scope, limit) do
    MemorySearchPage.read(MemorySearchPage.first(query, scope), limit, &search_page(context, &1))
  end

  @doc false
  def search_page(context, page) do
    case retrieval_context(context) do
      {:ok, context} -> search_visible_page(context, page)
      _ -> :done
    end
  end

  defp search_visible_page(context, page) do
    scoped = search_scope(context, page.scope)

    query =
      from(e in MemoryEntry,
        where:
          (e.workspace_ref == ^context.workspace_ref or e.scope_kind == :global) and
            e.status == :active and
            (is_nil(e.expires_at) or e.expires_at > fragment("clock_timestamp()")),
        where: ^scoped,
        where:
          e.visibility in [:workspace, :global] or
            (e.visibility == :conversation and
               e.source_conversation_ref == ^context.conversation_ref)
      )

    changed =
      dynamic(
        [e],
        type(fragment("COALESCE(?, ?)", e.edited_at, e.confirmed_at), :utc_datetime_usec)
      )

    text = dynamic([e], fragment("? || ' ' || ?", e.subject, e.payload))

    query
    |> MemorySearchPage.related_originals(
      page,
      dynamic([e], e.source_conversation_ref),
      dynamic([e], e.source_thread_ref),
      dynamic([e], e.source_message_ref)
    )
    |> MemorySearchPage.one(page, text, changed, dynamic([e], e.confirmed_at))
    |> account_search_result()
  end

  defp search_scope(context, "current_channel"),
    do: dynamic([e], e.scope_kind == :conversation and e.scope_ref == ^context.conversation_ref)

  defp search_scope(%{repository: repository}, "repository") when is_binary(repository),
    do: dynamic([e], e.scope_kind == :repository and e.scope_ref == ^repository)

  defp search_scope(context, "workspace"),
    do: dynamic([e], e.scope_kind == :workspace and e.scope_ref == ^context.workspace_ref)

  defp search_scope(_context, "global"), do: dynamic([e], e.scope_kind == :global)

  defp search_scope(_context, _scope), do: dynamic([e], false)

  defp account_search_result({:ok, entry, position}) do
    case account_memory([entry]) do
      [document] -> {:ok, document, position}
      [] -> {:skip, position}
    end
  end

  defp account_search_result(:done), do: :done

  # The thousand most recently updated entries this conversation may see. The
  # visibility rule is part of the query: with it applied afterwards, a
  # workspace whose other conversations held a thousand newer private entries
  # pushed an older shared fact out of the window before it was ever weighed.
  defp visible_entries(context) do
    now = Repo.now!()

    Repo.all(
      from(entry in MemoryEntry,
        where: ^visible(context),
        where: entry.status == :active and (is_nil(entry.expires_at) or entry.expires_at > ^now),
        order_by: [desc: entry.updated_at, desc: entry.id],
        limit: 1_000
      )
    )
  end

  defp visible(context) do
    scoped = scoped(context)

    dynamic(
      [entry],
      (entry.visibility == :conversation and
         entry.source_conversation_ref == ^context.conversation_ref and ^scoped) or
        (entry.visibility == :workspace and ^scoped) or
        (entry.visibility == :global and entry.scope_kind == :global)
    )
  end

  # An entry is in scope when it belongs to this workspace and its scope names
  # this conversation, this workspace, or the repository this session runs in.
  defp scoped(context) do
    kinds =
      dynamic(
        [entry],
        (entry.scope_kind == :conversation and entry.scope_ref == ^context.conversation_ref) or
          (entry.scope_kind == :workspace and entry.scope_ref == ^context.workspace_ref)
      )

    kinds =
      if is_binary(context.repository),
        do:
          dynamic(
            [entry],
            ^kinds or (entry.scope_kind == :repository and entry.scope_ref == ^context.repository)
          ),
        else: kinds

    dynamic([entry], entry.workspace_ref == ^context.workspace_ref and ^kinds)
  end

  defp account_memory(entries) do
    now = Repo.now!()

    unchanged =
      Enum.reduce(entries, dynamic(false), fn entry, condition ->
        dynamic(
          [current],
          ^condition or
            (current.id == ^entry.id and current.payload_fingerprint == ^entry.payload_fingerprint)
        )
      end)

    # The operator may revoke or edit a row while this UPDATE waits on its lock.
    # Charge and disclose only the exact still-active content we selected.
    {_count, ids} =
      if entries == [],
        do: {0, []},
        else:
          Repo.update_all(
            from(entry in MemoryEntry,
              where: ^unchanged,
              where:
                entry.status == :active and
                  (is_nil(entry.expires_at) or entry.expires_at > fragment("clock_timestamp()")),
              select: entry.id
            ),
            inc: [recall_count: 1],
            set: [last_recalled_at: now, updated_at: now]
          )

    retained = MapSet.new(ids)
    entries |> Enum.filter(&MapSet.member?(retained, &1.id)) |> Enum.map(&document/1)
  end

  defp rank(entry) do
    scope_rank =
      case entry.scope_kind do
        :conversation -> 0
        :repository -> 1
        :workspace -> 2
        :global -> 3
      end

    visibility_rank = if entry.visibility == :conversation, do: 0, else: 1
    recent = -DateTime.to_unix(entry.updated_at, :microsecond)

    {scope_rank, visibility_rank, recent, entry.ref}
  end

  defp document(entry) do
    %{
      "confirmed_at" => DateTime.to_iso8601(entry.confirmed_at),
      "expires_at" => Memories.datetime(entry.expires_at),
      "kind" => Atom.to_string(entry.kind),
      "memory_ref" => entry.ref,
      "scope" => Atom.to_string(entry.scope_kind),
      "source" => %{
        "conversation_ref" => entry.source_conversation_ref,
        "message_ref" => entry.source_message_ref,
        "thread_ref" => entry.source_thread_ref,
        "transport" => entry.source_transport
      },
      "source_read" =>
        MemorySourceLink.message(
          entry.source_transport,
          entry.source_conversation_ref,
          entry.source_message_ref,
          entry.source_thread_ref
        ),
      "subject" => entry.subject,
      "value" => entry.payload["value"],
      "visibility" => Atom.to_string(entry.visibility)
    }
    |> global_fact_document(entry)
    |> put_edit_provenance(entry)
  end

  defp global_fact_document(document, %MemoryEntry{scope_kind: :global} = entry) do
    # The confirmed mapping is installation-wide; its private source is not.
    document
    |> Map.drop(["source", "source_read"])
    |> Map.put("applicability", entry.payload["applicability"])
  end

  defp global_fact_document(document, _entry), do: document

  defp put_edit_provenance(document, %MemoryEntry{edited_at: %DateTime{} = edited_at} = entry) do
    Map.put(document, "edit", %{
      "actor_ref" => entry.edited_by_actor_ref,
      "edited_at" => DateTime.to_iso8601(edited_at),
      "review_ref" => entry.edit_review_ref
    })
  end

  defp put_edit_provenance(document, _entry), do: document

  defp retrieval_context(context) do
    fields = [:conversation_ref, :repository, :workspace_ref]

    if Map.keys(context) |> Enum.sort() == Enum.sort(fields) and
         Reference.valid?(context.conversation_ref) and
         Reference.valid?(context.workspace_ref) and
         (is_nil(context.repository) or Reference.valid?(context.repository)) do
      {:ok, context}
    else
      {:error, :invalid_memory_context}
    end
  end
end
