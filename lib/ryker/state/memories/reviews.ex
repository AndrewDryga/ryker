defmodule Ryker.State.Memories.Reviews do
  @moduledoc """
  The stale and exact-duplicate review queue over memory entries and guidance.

  Reviews are idempotent candidates keyed by a digest of their sources; an
  operator keeps, merges, edits, forgets, or dismisses them, and any entry
  change that leaves a pending review with nothing to decide dismisses it.
  Every writer here and in `Ryker.State.Memories` holds the review
  maintenance advisory lock first, so a review can never name an entry that
  a concurrent confirmation, forget, or revocation is replacing.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Reference
  alias Ryker.Repo

  alias Ryker.State.{
    Behavior,
    BehaviorChangeset,
    Memories,
    MemoryEntry,
    MemoryEntryChangeset,
    MemoryReviewItem,
    MemoryReviewItemChangeset
  }

  @maximum_reviews 100
  @maximum_home_review_entries 8
  @review_advisory_lock 7_152_019_552_843_112

  @doc "Creates idempotent stale and exact-duplicate review candidates."
  @spec refresh_reviews(String.t(), pos_integer()) ::
          {:ok, %{created: non_neg_integer()}} | {:error, term()}
  def refresh_reviews(workspace_ref, stale_seconds)
      when is_integer(stale_seconds) and stale_seconds > 0 do
    with :ok <- Memories.reference(workspace_ref, :workspace_ref) do
      Repo.transaction(fn ->
        lock_review_maintenance!()
        refresh_reviews_locked(workspace_ref, stale_seconds)
      end)
    end
  end

  def refresh_reviews(_workspace_ref, _stale_seconds),
    do: {:error, {:invalid_memory_review, :stale_seconds}}

  @doc false
  @spec refresh_all_reviews_in_transaction(pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh_all_reviews_in_transaction(stale_seconds)
      when is_integer(stale_seconds) and stale_seconds > 0 do
    if Repo.in_transaction?() do
      lock_review_maintenance!()

      workspaces =
        (Repo.all(
           from(entry in MemoryEntry,
             where: entry.status == :active,
             distinct: true,
             select: entry.workspace_ref
           )
         ) ++
           Repo.all(
             from(behavior in Behavior,
               where: behavior.kind == :guidance and behavior.status == :active,
               distinct: true,
               select: behavior.workspace_ref
             )
           ))
        |> Enum.uniq()

      created =
        Enum.reduce(workspaces, 0, fn workspace_ref, total ->
          %{created: count} = refresh_reviews_locked(workspace_ref, stale_seconds)
          total + count
        end)

      {:ok, created}
    else
      {:error, :memory_review_transaction_required}
    end
  end

  def refresh_all_reviews_in_transaction(_stale_seconds),
    do: {:error, {:invalid_memory_review, :stale_seconds}}

  @doc false
  @spec dismiss_invalid_reviews_in_transaction() :: :ok | {:error, term()}
  def dismiss_invalid_reviews_in_transaction do
    if Repo.in_transaction?() do
      lock_review_maintenance!()
      dismiss_orphan_reviews("system:memory-retention")
    else
      {:error, :memory_review_transaction_required}
    end
  end

  @spec list_reviews(String.t(), keyword()) :: [map()]
  def list_reviews(workspace_ref, options \\ []) do
    with :ok <- Memories.reference(workspace_ref, :workspace_ref),
         {:ok, status, limit} <- review_list_options(options) do
      review_query(workspace_ref, status, limit)
      |> Repo.all()
      |> Enum.map(&review_document/1)
    else
      {:error, _reason} -> []
    end
  end

  @doc "Returns an actor-filtered App Home page and its exact pending total."
  @spec home_reviews(String.t(), String.t(), keyword()) :: %{
          items: [map()],
          total: non_neg_integer()
        }
  def home_reviews(workspace_ref, actor_ref, options \\ []) do
    with :ok <- Memories.reference(workspace_ref, :workspace_ref),
         :ok <- Memories.reference(actor_ref, :actor_ref),
         {:ok, status, limit} <- review_list_options(options) do
      query = home_review_query(workspace_ref, actor_ref, status)

      items =
        query
        |> where(
          [review],
          fragment(
            "jsonb_array_length(?::jsonb) <= ?",
            review.entry_refs,
            ^@maximum_home_review_entries
          )
        )
        |> order_by([review], asc: review.inserted_at, asc: review.id)
        |> limit(^limit)
        |> Repo.all()
        |> Enum.map(&review_document/1)

      %{items: items, total: Repo.aggregate(query, :count, :id)}
    else
      {:error, _reason} -> %{items: [], total: 0}
    end
  end

  @spec home_review_count(String.t(), String.t()) :: non_neg_integer()
  def home_review_count(workspace_ref, actor_ref) do
    with :ok <- Memories.reference(workspace_ref, :workspace_ref),
         :ok <- Memories.reference(actor_ref, :actor_ref) do
      workspace_ref
      |> home_review_query(actor_ref, :pending)
      |> Repo.aggregate(:count, :id)
    else
      {:error, _reason} -> 0
    end
  end

  @spec pending_reviews(pos_integer()) :: [map()]
  def pending_reviews(limit \\ 20)

  def pending_reviews(limit) when is_integer(limit) and limit in 1..@maximum_reviews do
    Repo.all(
      from(review in MemoryReviewItem,
        where: review.status == :pending,
        order_by: [asc: review.inserted_at, asc: review.id],
        limit: ^limit
      )
    )
    |> Enum.map(&review_document/1)
  end

  def pending_reviews(_limit), do: []

  @spec fetch_review(String.t()) :: {:ok, map()} | :error
  def fetch_review(ref) do
    if Reference.valid?(ref) do
      case Repo.one(from(review in MemoryReviewItem, where: review.ref == ^ref)) do
        %MemoryReviewItem{} = review -> {:ok, review_document(review)}
        nil -> :error
      end
    else
      :error
    end
  end

  @doc "Fetches one pending review only when every entry is safe for this App Home actor."
  @spec fetch_home_review(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :memory_review_not_found}
  def fetch_home_review(review_ref, workspace_ref, actor_ref) do
    with :ok <- Memories.reference(review_ref, :review_ref),
         :ok <- Memories.reference(workspace_ref, :workspace_ref),
         :ok <- Memories.reference(actor_ref, :actor_ref),
         %MemoryReviewItem{} = review <-
           Repo.one(
             from(review in home_review_query(workspace_ref, actor_ref, :pending),
               where: review.ref == ^review_ref
             )
           ) do
      {:ok, review_document(review)}
    else
      _unavailable -> {:error, :memory_review_not_found}
    end
  end

  @spec resolve_review(String.t(), atom(), String.t(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve_review(review_ref, action, actor_ref, workspace_ref, replacement \\ nil) do
    with :ok <- Memories.reference(review_ref, :review_ref),
         :ok <- review_action(action),
         :ok <- Memories.reference(actor_ref, :actor_ref),
         :ok <- Memories.reference(workspace_ref, :workspace_ref),
         {:ok, replacement} <- review_replacement(action, replacement) do
      Repo.transaction(fn ->
        lock_review_maintenance!()
        resolve_review_locked(review_ref, action, actor_ref, workspace_ref, replacement, :any)
      end)
    end
  end

  @doc "Resolves a review only when every affected entry is safe in the actor's App Home."
  @spec resolve_home_review(String.t(), atom(), String.t(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve_home_review(review_ref, action, actor_ref, workspace_ref, replacement \\ nil) do
    with :ok <- Memories.reference(review_ref, :review_ref),
         :ok <- review_action(action),
         :ok <- Memories.reference(actor_ref, :actor_ref),
         :ok <- Memories.reference(workspace_ref, :workspace_ref),
         {:ok, replacement} <- review_replacement(action, replacement) do
      Repo.transaction(fn ->
        lock_review_maintenance!()

        resolve_review_locked(
          review_ref,
          action,
          actor_ref,
          workspace_ref,
          replacement,
          {:home_actor, actor_ref}
        )
      end)
    end
  end

  @doc false
  @spec delete_slack_channel_in_transaction(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_slack_channel_in_transaction(workspace_ref, channel_ref)
      when is_binary(workspace_ref) and is_binary(channel_ref) do
    if Repo.in_transaction?() do
      lock_review_maintenance!()
      conversation_ref = "slack:#{workspace_ref}:#{channel_ref}"
      scoped_workspace_ref = "slack:#{workspace_ref}"

      delete_channel_facts(scoped_workspace_ref, conversation_ref)

      # Conversation-scoped guidance, and repository guidance the deleted
      # channel alone could see: its only surface is gone with the channel.
      Repo.all(
        from(behavior in Behavior,
          where:
            behavior.workspace_ref == ^scoped_workspace_ref and
              behavior.status in [:active, :disabled] and
              ((behavior.scope_kind == :conversation and
                  behavior.scope_ref == ^conversation_ref) or
                 (behavior.source_conversation_ref == ^conversation_ref and
                    fragment("?::jsonb->>'visibility' = 'conversation'", behavior.payload))),
          order_by: [asc: behavior.ref],
          lock: "FOR UPDATE"
        )
      )
      |> Enum.each(fn behavior ->
        redact_review_source!(
          review_source_record(:guidance, behavior),
          :deleted,
          "channel_deleted_payload_sha256"
        )
      end)

      dismiss_orphan_reviews("system:slack-channel-deletion", scoped_workspace_ref)
      dismiss_orphan_reviews("system:slack-channel-deletion", "installation")
      :ok
    else
      {:error, :memory_review_transaction_required}
    end
  end

  def delete_slack_channel_in_transaction(_workspace_ref, _channel_ref),
    do: {:error, {:invalid_memory_review, :conversation}}

  # Facts the deleted channel alone could see (conversation-scoped, and
  # repository-scoped with conversation visibility), and the global facts
  # answered from a message in it. Workspace-visible facts outlive the channel
  # they were confirmed in.
  defp delete_channel_facts(workspace_ref, conversation_ref) do
    Repo.all(
      from(entry in MemoryEntry,
        where:
          entry.status == :active and
            ((entry.workspace_ref == ^workspace_ref and entry.scope_kind == :conversation and
                entry.scope_ref == ^conversation_ref) or
               (entry.workspace_ref == ^workspace_ref and entry.visibility == :conversation and
                  entry.source_conversation_ref == ^conversation_ref) or
               (entry.scope_kind == :global and entry.source_conversation_ref == ^conversation_ref)),
        order_by: [asc: entry.ref],
        lock: "FOR UPDATE"
      )
    )
    |> Enum.each(&Memories.redact!(&1, :deleted, "channel_deleted_payload_sha256"))
  end

  defp refresh_reviews_locked(workspace_ref, stale_seconds) do
    now = Repo.now!()
    stale_before = DateTime.add(now, -stale_seconds, :second)

    memory_entries =
      Repo.all(
        from(entry in MemoryEntry,
          where:
            entry.workspace_ref == ^workspace_ref and entry.status == :active and
              (is_nil(entry.expires_at) or entry.expires_at > ^now),
          order_by: [asc: entry.updated_at, asc: entry.id],
          limit: 1_000
        )
      )

    guidance =
      Repo.all(
        from(behavior in Behavior,
          where:
            behavior.workspace_ref == ^workspace_ref and behavior.kind == :guidance and
              behavior.status == :active and
              (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
          order_by: [asc: behavior.updated_at, asc: behavior.id],
          limit: 500
        )
      )

    sources =
      Enum.map(memory_entries, &review_source_record(:memory, &1)) ++
        Enum.map(guidance, &review_source_record(:guidance, &1))

    stale =
      Enum.filter(sources, &stale_review_source?(&1, stale_before))

    duplicate_groups =
      sources
      |> Enum.group_by(&duplicate_identity/1)
      |> Map.values()
      |> Enum.filter(&(length(&1) > 1))

    candidates =
      Enum.map(stale, &{:stale, [&1], "This memory has not been recalled or reviewed recently."}) ++
        Enum.map(duplicate_groups, fn group ->
          {:duplicate, group, "These entries have the same meaning in the same scope."}
        end)

    created = Enum.count(candidates, &ensure_review(workspace_ref, &1))
    dismiss_orphan_reviews("system:memory-review", workspace_ref)
    %{created: created}
  end

  defp ensure_review(workspace_ref, {kind, entries, reason}) do
    entries = Enum.sort_by(entries, &review_entry_ref/1)

    digest =
      CanonicalJSON.digest(%{
        "entries" => Enum.map(entries, &review_source(kind, &1)),
        "kind" => Atom.to_string(kind)
      })

    if Repo.exists?(from(review in MemoryReviewItem, where: review.source_digest == ^digest)) do
      false
    else
      id = Ecto.UUID.generate()

      changeset =
        %{
          entry_refs: Enum.map(entries, &review_entry_ref/1),
          id: id,
          kind: kind,
          reason: reason,
          ref: "memory-review:#{id}",
          source_digest: digest,
          status: :pending,
          workspace_ref: workspace_ref
        }
        |> MemoryReviewItemChangeset.insert()

      changeset |> Repo.insert() |> review_inserted()
    end
  end

  defp review_inserted({:ok, _review}), do: true

  defp review_inserted({:error, changeset}) do
    if Keyword.has_key?(changeset.errors, :source_digest),
      do: false,
      else: Repo.rollback({:memory_review_persistence, changeset.errors})
  end

  defp review_source(:duplicate, source), do: review_identity(source)

  defp review_source(:stale, source) do
    source
    |> review_identity()
    |> Map.merge(%{
      "last_reviewed_at" => Memories.datetime(review_last_reviewed_at(source)),
      "last_used_at" => Memories.datetime(review_last_used_at(source)),
      "updated_at" => DateTime.to_iso8601(source.record.updated_at)
    })
  end

  defp review_query(workspace_ref, status, limit) do
    query =
      from(review in MemoryReviewItem,
        where: review.workspace_ref == ^workspace_ref,
        order_by: [asc: review.inserted_at, asc: review.id],
        limit: ^limit
      )

    if status, do: from(review in query, where: review.status == ^status), else: query
  end

  defp home_review_query(workspace_ref, actor_ref, status) do
    query =
      from(review in MemoryReviewItem,
        where: review.workspace_ref == ^workspace_ref,
        where: ^home_review_authorization_filter(workspace_ref, actor_ref)
      )

    if status, do: from(review in query, where: review.status == ^status), else: query
  end

  defp home_review_authorization_filter(workspace_ref, actor_ref) do
    dynamic(
      [review],
      fragment(
        """
        jsonb_array_length(?::jsonb) > 0 AND NOT EXISTS (
          SELECT 1
          FROM jsonb_array_elements_text(?::jsonb) AS source(ref)
          WHERE NOT (
            EXISTS (
              SELECT 1 FROM operational_memory_entries AS memory
              WHERE memory.ref = source.ref
                AND memory.workspace_ref = ?
                AND memory.visibility = 'workspace'
                AND memory.scope_kind IN ('repository', 'workspace')
            ) OR EXISTS (
              SELECT 1 FROM operator_behaviors AS behavior
              WHERE behavior.ref = source.ref
                AND behavior.workspace_ref = ?
                AND (
                  (behavior.scope_kind = 'operator' AND behavior.scope_ref = ?) OR
                  (behavior.scope_kind IN ('repository', 'workspace') AND
                    behavior.payload::jsonb->>'visibility' = 'workspace')
                )
            )
          )
        )
        """,
        review.entry_refs,
        review.entry_refs,
        ^workspace_ref,
        ^workspace_ref,
        ^actor_ref
      )
    )
  end

  defp resolve_review_locked(
         review_ref,
         action,
         actor_ref,
         workspace_ref,
         replacement,
         authorization
       ) do
    case Repo.one(
           from(review in MemoryReviewItem, where: review.ref == ^review_ref, lock: "FOR UPDATE")
         ) do
      nil ->
        Repo.rollback(:memory_review_not_found)

      %MemoryReviewItem{workspace_ref: actual} when actual != workspace_ref ->
        Repo.rollback(:memory_review_workspace_mismatch)

      %MemoryReviewItem{status: status} = review when status != :pending ->
        case review_authorized(review, workspace_ref, authorization) do
          :ok -> resolved_review_result(review, action, actor_ref, replacement)
          {:error, reason} -> Repo.rollback(reason)
        end

      %MemoryReviewItem{} = review ->
        entries = lock_review_entries(review.entry_refs, workspace_ref)

        with :ok <- review_authorized_entries(entries, authorization),
             :ok <- review_entries_current(review, entries),
             :ok <- apply_review_action(review, entries, action, replacement, actor_ref),
             {:ok, review} <-
               review
               |> MemoryReviewItemChangeset.resolve(%{
                 action: action,
                 replacement: review_audit_replacement(action, replacement),
                 reviewed_at: Repo.now!(),
                 reviewed_by_actor_ref: actor_ref,
                 status: review_status(action)
               })
               |> Repo.update() do
          dismiss_superseded_reviews(review, entries, action, actor_ref)
          dismiss_orphan_reviews(actor_ref)

          %{
            entries: Enum.map(entries, &review_entry_document/1),
            review: review_document(review),
            status: :resolved
          }
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp resolved_review_result(review, action, actor_ref, replacement) do
    if review.action == action and review.reviewed_by_actor_ref == actor_ref and
         review.replacement == review_audit_replacement(action, replacement) do
      %{entries: [], review: review_document(review), status: :duplicate}
    else
      Repo.rollback(:memory_review_conflict)
    end
  end

  defp lock_review_entries(entry_refs, workspace_ref) do
    memories = lock_review_memories(entry_refs, workspace_ref)

    guidance =
      Repo.all(
        from(behavior in Behavior,
          where:
            behavior.ref in ^entry_refs and behavior.workspace_ref == ^workspace_ref and
              behavior.kind == :guidance and behavior.status == :active and
              (is_nil(behavior.expires_at) or
                 behavior.expires_at > fragment("clock_timestamp()")),
          order_by: [asc: behavior.ref],
          lock: "FOR UPDATE"
        )
      )
      |> Enum.map(&review_source_record(:guidance, &1))

    Enum.sort_by(memories ++ guidance, &review_entry_ref/1)
  end

  defp lock_review_memories(entry_refs, workspace_ref) do
    Repo.all(
      from(entry in MemoryEntry,
        where:
          entry.ref in ^entry_refs and entry.workspace_ref == ^workspace_ref and
            entry.status == :active and
            (is_nil(entry.expires_at) or entry.expires_at > fragment("clock_timestamp()")),
        order_by: [asc: entry.ref],
        lock: "FOR UPDATE"
      )
    )
    |> Enum.map(&review_source_record(:memory, &1))
  end

  defp review_entries_current(review, entries) do
    digest =
      CanonicalJSON.digest(%{
        "entries" => Enum.map(entries, &review_source(review.kind, &1)),
        "kind" => Atom.to_string(review.kind)
      })

    if length(entries) == length(review.entry_refs) and
         Enum.map(entries, &review_entry_ref/1) == Enum.sort(review.entry_refs) and
         digest == review.source_digest,
       do: :ok,
       else: {:error, :memory_review_stale}
  end

  defp apply_review_action(_review, entries, action, _replacement, _actor_ref)
       when action in [:keep, :dismiss] do
    now = Repo.now!()
    Enum.each(entries, &review_source!(&1, now))
    :ok
  end

  defp apply_review_action(_review, entries, :forget, _replacement, _actor_ref) do
    Enum.each(entries, &redact_review_source!(&1, :deleted, "forgotten_payload_sha256"))
    :ok
  end

  defp apply_review_action(
         %MemoryReviewItem{kind: :duplicate},
         [_keep, _drop | _rest] = entries,
         :merge,
         nil,
         _actor_ref
       ) do
    [keep | duplicates] = Enum.sort_by(entries, &review_survivor_rank/1)
    now = Repo.now!()
    review_source!(keep, now)
    Enum.each(duplicates, &redact_review_source!(&1, :superseded, "merged_payload_sha256"))
    :ok
  end

  defp apply_review_action(_review, _entries, :merge, _replacement, _actor_ref),
    do: {:error, :memory_review_cannot_merge}

  defp apply_review_action(
         %MemoryReviewItem{kind: :stale} = review,
         [entry],
         :edit,
         replacement,
         actor_ref
       ),
       do: edit_review_source(entry, review, replacement, actor_ref)

  defp apply_review_action(_review, _entries, :edit, _replacement, _actor_ref),
    do: {:error, :memory_review_cannot_edit}

  @doc false
  def dismiss_orphan_reviews(actor_ref, workspace_ref \\ nil) do
    now = Repo.now!()

    query = from(review in MemoryReviewItem, where: review.status == :pending, lock: "FOR UPDATE")

    query =
      if workspace_ref,
        do: from(review in query, where: review.workspace_ref == ^workspace_ref),
        else: query

    Repo.all(query)
    |> Enum.filter(fn review ->
      review_entries_current(
        review,
        lock_review_entries(review.entry_refs, review.workspace_ref)
      ) != :ok
    end)
    |> Enum.each(fn review ->
      review
      |> MemoryReviewItemChangeset.resolve(%{
        action: :dismiss,
        replacement: nil,
        reviewed_at: now,
        reviewed_by_actor_ref: actor_ref,
        status: :dismissed
      })
      |> Repo.update!()
    end)
  end

  defp dismiss_superseded_reviews(_review, _entries, action, _actor_ref)
       when action in [:keep, :dismiss],
       do: :ok

  defp dismiss_superseded_reviews(review, entries, _action, actor_ref) do
    refs = MapSet.new(entries, &review_entry_ref/1)
    now = Repo.now!()

    Repo.all(
      from(item in MemoryReviewItem,
        where: item.status == :pending and item.id != ^review.id,
        lock: "FOR UPDATE"
      )
    )
    |> Enum.filter(fn item ->
      item.entry_refs |> MapSet.new() |> MapSet.disjoint?(refs) |> Kernel.not()
    end)
    |> Enum.each(fn item ->
      item
      |> MemoryReviewItemChangeset.resolve(%{
        action: :dismiss,
        replacement: nil,
        reviewed_at: now,
        reviewed_by_actor_ref: actor_ref,
        status: :dismissed
      })
      |> Repo.update!()
    end)

    :ok
  end

  defp review_document(review) do
    entries = review_documents(review.entry_refs)

    %{
      "action" => review.action && Atom.to_string(review.action),
      "entries" => entries,
      "kind" => Atom.to_string(review.kind),
      "reason" => review.reason,
      "review_ref" => review.ref,
      "status" => Atom.to_string(review.status)
    }
  end

  defp entry_document(entry) do
    %{
      "kind" => Atom.to_string(entry.kind),
      "memory_ref" => entry.ref,
      "status" => Atom.to_string(entry.status),
      "subject" => entry.subject,
      "value" => entry.payload["value"]
    }
  end

  defp review_documents(entry_refs) do
    memories =
      Repo.all(
        from(entry in MemoryEntry,
          where: entry.ref in ^entry_refs,
          order_by: [asc: entry.ref]
        )
      )
      |> Enum.map(&review_source_record(:memory, &1))

    guidance =
      Repo.all(
        from(behavior in Behavior,
          where: behavior.ref in ^entry_refs,
          order_by: [asc: behavior.ref]
        )
      )
      |> Enum.map(&review_source_record(:guidance, &1))

    (memories ++ guidance)
    |> Enum.sort_by(&review_entry_ref/1)
    |> Enum.map(&review_entry_document/1)
  end

  @doc false
  def review_source_record(type, record), do: %{record: record, type: type}

  defp review_entry_ref(%{record: record}), do: record.ref

  defp review_survivor_rank(%{record: record}) do
    {-DateTime.to_unix(record.updated_at, :microsecond), record.ref}
  end

  defp review_authorized(_review, _workspace_ref, :any), do: :ok

  defp review_authorized(review, workspace_ref, {:home_actor, actor_ref}) do
    sources = review_sources(review.entry_refs, workspace_ref)

    if length(sources) == length(review.entry_refs) and
         length(sources) <= @maximum_home_review_entries and
         Enum.all?(sources, &home_source_visible?(&1, actor_ref)),
       do: :ok,
       else: {:error, :memory_review_unauthorized}
  end

  defp review_authorized_entries(_entries, :any), do: :ok

  defp review_authorized_entries(entries, {:home_actor, actor_ref}) do
    if length(entries) <= @maximum_home_review_entries and
         Enum.all?(entries, &home_source_visible?(&1, actor_ref)),
       do: :ok,
       else: {:error, :memory_review_unauthorized}
  end

  @doc false
  def home_source_visible?(
        %{type: :memory, record: %MemoryEntry{} = entry},
        _actor_ref
      ),
      do: entry.visibility == :workspace and entry.scope_kind in [:repository, :workspace]

  def home_source_visible?(
        %{type: :guidance, record: %Behavior{scope_kind: :operator, scope_ref: actor_ref}},
        actor_ref
      ),
      do: true

  def home_source_visible?(%{type: :guidance, record: %Behavior{} = behavior}, _actor_ref),
    do:
      behavior.scope_kind in [:repository, :workspace] and
        behavior.payload["visibility"] == "workspace"

  def home_source_visible?(_source, _actor_ref), do: false

  defp review_sources(entry_refs, workspace_ref) do
    memory_query =
      from(entry in MemoryEntry,
        where: entry.ref in ^entry_refs and entry.workspace_ref == ^workspace_ref,
        order_by: [asc: entry.ref],
        lock: "FOR UPDATE"
      )

    guidance_query =
      from(behavior in Behavior,
        where: behavior.ref in ^entry_refs and behavior.workspace_ref == ^workspace_ref,
        order_by: [asc: behavior.ref],
        lock: "FOR UPDATE"
      )

    (Enum.map(Repo.all(memory_query), &review_source_record(:memory, &1)) ++
       Enum.map(Repo.all(guidance_query), &review_source_record(:guidance, &1)))
    |> Enum.sort_by(&review_entry_ref/1)
  end

  defp review_identity(%{type: :memory, record: entry}) do
    %{
      "payload_fingerprint" => entry.payload_fingerprint,
      "ref" => entry.ref,
      "source_type" => "memory",
      "subject" => entry.subject
    }
  end

  defp review_identity(%{type: :guidance, record: behavior}) do
    %{
      "payload_fingerprint" => CanonicalJSON.digest(behavior.payload),
      "ref" => behavior.ref,
      "source_type" => "guidance",
      "subject" => behavior.identity_key
    }
  end

  defp review_last_reviewed_at(%{record: record}), do: record.last_reviewed_at
  defp review_last_used_at(%{type: :memory, record: entry}), do: entry.last_recalled_at
  defp review_last_used_at(%{type: :guidance, record: behavior}), do: behavior.last_used_at

  defp stale_review_source?(source, stale_before) do
    record = source.record

    DateTime.before?(record.updated_at, stale_before) and
      (is_nil(review_last_used_at(source)) or
         DateTime.before?(review_last_used_at(source), stale_before)) and
      (is_nil(review_last_reviewed_at(source)) or
         DateTime.before?(review_last_reviewed_at(source), stale_before))
  end

  defp duplicate_identity(%{type: :memory, record: entry}) do
    {:memory, entry.scope_kind, entry.scope_ref, entry.visibility, entry.kind, entry.subject,
     entry.payload["value"]}
  end

  defp duplicate_identity(%{type: :guidance, record: behavior}) do
    {:guidance, behavior.scope_kind, behavior.scope_ref, behavior.payload["visibility"],
     behavior.payload["text"]}
  end

  defp review_source!(%{type: :memory, record: entry}, now) do
    entry |> MemoryEntryChangeset.review(now) |> Repo.update!()
  end

  defp review_source!(%{type: :guidance, record: behavior}, now) do
    behavior
    |> BehaviorChangeset.update(%{last_reviewed_at: now})
    |> Repo.update!()
  end

  defp redact_review_source!(%{type: :memory, record: entry}, status, hash_field),
    do: Memories.redact!(entry, status, hash_field)

  defp redact_review_source!(%{type: :guidance, record: behavior}, status, hash_field) do
    payload = %{hash_field => CanonicalJSON.digest(behavior.payload)}

    behavior
    |> BehaviorChangeset.update(%{
      payload: payload,
      revision: behavior.revision + 1,
      status: status
    })
    |> Repo.update!()
  end

  defp edit_review_source(%{type: :memory, record: entry}, review, replacement, actor_ref) do
    payload =
      entry.payload
      |> Map.put("subject", replacement["subject"])
      |> Map.put("value", replacement["value"])

    fingerprint = CanonicalJSON.digest(payload)

    entry
    |> MemoryEntryChangeset.edit(
      replacement["subject"],
      payload,
      fingerprint,
      Repo.now!(),
      actor_ref,
      review.ref
    )
    |> Repo.update()
    |> review_edit_result()
  end

  defp edit_review_source(%{type: :guidance, record: behavior}, review, replacement, actor_ref) do
    now = Repo.now!()

    payload =
      behavior.payload
      |> Map.put("subject", replacement["subject"])
      |> Map.put("summary", String.slice(replacement["value"], 0, 500))
      |> Map.put("text", replacement["value"])

    behavior
    |> BehaviorChangeset.update(%{
      edited_at: now,
      edited_by_actor_ref: actor_ref,
      edit_review_ref: review.ref,
      identity_key: replacement["subject"],
      last_reviewed_at: now,
      payload: payload,
      revision: behavior.revision + 1
    })
    |> Repo.update()
    |> review_edit_result()
  end

  defp review_edit_result({:ok, _entry}), do: :ok

  defp review_edit_result({:error, changeset}),
    do: {:error, {:memory_review_edit_failed, changeset.errors}}

  defp review_entry_document(%{type: :memory, record: entry}) do
    entry_document(entry)
    |> Map.merge(%{
      "confirmed_at" => DateTime.to_iso8601(entry.confirmed_at),
      "last_recalled_at" => Memories.datetime(entry.last_recalled_at),
      "recall_count" => entry.recall_count,
      "scope" => Atom.to_string(entry.scope_kind),
      "scope_ref" => entry.scope_ref,
      "source_conversation_ref" => entry.source_conversation_ref,
      "source_thread_ref" => entry.source_thread_ref,
      "source_transport" => entry.source_transport,
      "source_type" => "memory",
      "visibility" => Atom.to_string(entry.visibility)
    })
  end

  defp review_entry_document(%{type: :guidance, record: behavior}) do
    %{
      "confirmed_at" => DateTime.to_iso8601(behavior.confirmed_at),
      "kind" => "guidance",
      "last_recalled_at" => Memories.datetime(behavior.last_used_at),
      "memory_ref" => behavior.ref,
      "recall_count" => behavior.use_count,
      "scope" => Atom.to_string(behavior.scope_kind),
      "scope_ref" => behavior.scope_ref,
      "source_conversation_ref" => behavior.source_conversation_ref,
      "source_thread_ref" => behavior.source_thread_ref,
      "source_transport" => behavior.source_transport,
      "source_type" => "guidance",
      "status" => Atom.to_string(behavior.status),
      "subject" => behavior.identity_key,
      "value" => behavior.payload["text"],
      "visibility" => behavior.payload["visibility"]
    }
  end

  defp review_audit_replacement(:edit, replacement) do
    %{"replacement_payload_sha256" => CanonicalJSON.digest(replacement)}
  end

  defp review_audit_replacement(_action, _replacement), do: nil

  defp review_list_options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- [:limit, :status] == [] do
      status = Keyword.get(options, :status, :pending)
      limit = Keyword.get(options, :limit, 20)

      if (is_nil(status) or status in [:pending, :kept, :applied, :dismissed]) and
           is_integer(limit) and limit in 1..@maximum_reviews,
         do: {:ok, status, limit},
         else: {:error, {:invalid_memory_review, :options}}
    else
      {:error, {:invalid_memory_review, :options}}
    end
  end

  defp review_list_options(_options), do: {:error, {:invalid_memory_review, :options}}

  defp review_action(action) when action in [:keep, :merge, :edit, :forget, :dismiss], do: :ok
  defp review_action(_action), do: {:error, {:invalid_memory_review, :action}}

  defp review_replacement(:edit, %{"subject" => subject, "value" => value} = replacement)
       when map_size(replacement) == 2 do
    if text?(subject, 120) and text?(value, 4_000),
      do: {:ok, replacement},
      else: {:error, {:invalid_memory_review, :replacement}}
  end

  defp review_replacement(:edit, _replacement),
    do: {:error, {:invalid_memory_review, :replacement}}

  defp review_replacement(_action, nil), do: {:ok, nil}

  defp review_replacement(_action, _replacement),
    do: {:error, {:invalid_memory_review, :replacement}}

  defp review_status(action) when action in [:keep], do: :kept
  defp review_status(:dismiss), do: :dismissed
  defp review_status(action) when action in [:merge, :edit, :forget], do: :applied

  defp text?(value, maximum) do
    is_binary(value) and String.valid?(value) and String.length(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  @doc false
  def lock_review_maintenance! do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@review_advisory_lock])
    :ok
  end
end
