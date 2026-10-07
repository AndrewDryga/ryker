defmodule Ryker.Memories.Recall do
  @moduledoc """
  Reads confirmed memory for one exact model context.

  Recall ranks the entries a conversation, repository, and workspace may see;
  search pages through them by relevance. Both charge a recall against the
  exact still-active row that was selected, so a fact the operator revoked or
  edited while the read waited is neither disclosed nor counted.
  """

  alias Ryker.Episodes.Episode
  alias Ryker.Episodes.Scope
  alias Ryker.Memories
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Memories.MemoryEntryQuery
  alias Ryker.Memories.MemorySearchPage
  alias Ryker.Memories.MemorySourceLink
  alias Ryker.Memories.SearchPageQuery
  alias Ryker.Reference
  alias Ryker.Repo

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

  @spec model_context(Episode.t(), String.t() | nil) :: [map()]
  def model_context(%Episode{} = episode, repository)
      when is_binary(repository) or is_nil(repository) do
    recall(%{
      conversation_ref: episode.destination_conversation_ref,
      execution_mode: episode.execution_mode,
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

    account_memory(entries, context)
  end

  @doc false
  def search_page(context, page) do
    case retrieval_context(context) do
      {:ok, context} -> search_visible_page(context, page)
      _ -> :done
    end
  end

  defp search_visible_page(context, page) do
    fields = MemoryEntryQuery.search_fields()

    context
    |> MemoryEntryQuery.searchable()
    |> MemoryEntryQuery.in_search_scope(context, page.scope)
    |> SearchPageQuery.related_originals(
      page,
      fields.conversation,
      fields.thread,
      fields.message
    )
    |> MemorySearchPage.one(page, fields.text, fields.changed, fields.source)
    |> account_search_result(context)
  end

  defp account_search_result({:ok, entry, position}, context) do
    case account_memory([entry], context) do
      [document] -> {:ok, document, position}
      [] -> {:skip, position}
    end
  end

  defp account_search_result(:done, _context), do: :done

  # The thousand entries with the newest content this conversation may see. The
  # visibility rule is part of the query: with it applied afterwards, a
  # workspace whose other conversations held a thousand newer private entries
  # pushed an older shared fact out of the window before it was ever weighed.
  defp visible_entries(context) do
    MemoryEntryQuery.all()
    |> MemoryEntryQuery.visible_to(context)
    |> MemoryEntryQuery.active()
    |> MemoryEntryQuery.unexpired_at(Repo.now!())
    |> MemoryEntryQuery.newest_content_first()
    |> MemoryEntryQuery.limit_to(1_000)
    |> Repo.all()
  end

  defp account_memory([], _context), do: []

  defp account_memory(entries, context) do
    # The operator may revoke or edit a row while this UPDATE waits on its lock.
    # Charge and disclose only the exact still-active content we selected.
    current =
      entries
      |> MemoryEntryQuery.unchanged()
      |> MemoryEntryQuery.active()
      |> MemoryEntryQuery.unexpired()
      |> MemoryEntryQuery.select_ids()

    ids = charge(current, context)
    retained = MapSet.new(ids)
    entries |> Enum.filter(&MapSet.member?(retained, &1.id)) |> Enum.map(&document/1)
  end

  # A shadow turn reads what a live one would and counts no use: its reads kept
  # stale facts out of the review queue (2026-10-04 review).
  defp charge(current, %{execution_mode: :shadow}), do: Repo.all(current)

  defp charge(current, _context) do
    {_count, ids} =
      Repo.update_all(current, inc: [recall_count: 1], set: [last_recalled_at: Repo.now!()])

    Enum.each(ids, &Ryker.Memories.broadcast_memory_updated/1)
    ids
  end

  # When the fact itself was last said: edited, else confirmed, else saved.
  # Recall counts in recall_count and last_recalled_at and never here; a fact
  # recalled once used to outrank every newer one from then on (2026-09-28).
  defp content_at(entry), do: entry.edited_at || entry.confirmed_at || entry.inserted_at

  defp rank(entry) do
    scope_rank =
      case entry.scope_kind do
        :conversation -> 0
        :repository -> 1
        :workspace -> 2
        :global -> 3
      end

    visibility_rank = if entry.visibility == :conversation, do: 0, else: 1
    recent = -DateTime.to_unix(content_at(entry), :microsecond)

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

    if Map.get(context, :execution_mode, :live) in [:live, :shadow] and
         (Map.keys(context) -- [:execution_mode]) |> Enum.sort() == Enum.sort(fields) and
         Reference.valid?(context.conversation_ref) and
         Reference.valid?(context.workspace_ref) and
         (is_nil(context.repository) or Reference.valid?(context.repository)) do
      {:ok, context}
    else
      {:error, :invalid_memory_context}
    end
  end
end
