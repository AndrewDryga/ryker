defmodule Responder.State.Memories do
  @moduledoc """
  Operator-confirmed operational memory with exact scope and provenance.

  Memory is a potentially stale model hint. It cannot start work, satisfy an
  evidence requirement, choose a repository policy, or authorize an effect.
  Replacement and forgetting erase the stored value while retaining only its
  digest and lifecycle identity.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.Slack.ChannelFence

  alias Responder.State.{
    Behavior,
    BehaviorChangeset,
    MemoryEntry,
    MemoryEntryChangeset,
    MemoryReviewItem,
    MemoryReviewItemChangeset,
    Record,
    RecordChangeset
  }

  alias Responder.Work.Turn

  @confirmation_fields [:actor_ref, :confirmation_ref, :occurred_at, :record_ref, :target]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]
  @maximum_total 1_000
  @maximum_per_scope 100
  @maximum_reviews 100
  @maximum_home_review_entries 8
  @review_advisory_lock 7_152_019_552_843_112

  @spec confirm(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def confirm(attributes) do
    with {:ok, attributes} <- confirmation_attributes(attributes),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.confirmation_ref, :confirmation_ref),
         :ok <- reference(attributes.record_ref, :record_ref),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        confirm_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
      |> transaction_result()
    end
  end

  @spec forget(String.t()) :: {:ok, MemoryEntry.t()} | {:error, term()}
  def forget(ref) do
    with :ok <- reference(ref, :memory_ref) do
      Repo.transaction(fn ->
        lock_review_maintenance!()
        entry = forget_locked(ref, nil)
        dismiss_orphan_reviews("system:memory-forget")
        entry
      end)
      |> transaction_result()
    end
  end

  @spec forget(String.t(), String.t()) :: {:ok, MemoryEntry.t()} | {:error, term()}
  def forget(ref, workspace_ref) do
    with :ok <- reference(ref, :memory_ref),
         :ok <- reference(workspace_ref, :workspace_ref) do
      Repo.transaction(fn ->
        lock_review_maintenance!()
        entry = forget_locked(ref, workspace_ref)
        dismiss_orphan_reviews("system:memory-forget", workspace_ref)
        entry
      end)
      |> transaction_result()
    end
  end

  @doc "Forgets shared App Home memory without granting access to channel-only entries."
  @spec forget_home(String.t(), String.t(), String.t()) ::
          {:ok, MemoryEntry.t()} | {:error, term()}
  def forget_home(ref, actor_ref, workspace_ref) do
    with :ok <- reference(ref, :memory_ref),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(workspace_ref, :workspace_ref) do
      Repo.transaction(fn ->
        lock_review_maintenance!()
        forget_home_locked(ref, actor_ref, workspace_ref)
      end)
      |> transaction_result()
    end
  end

  defp forget_home_locked(ref, actor_ref, workspace_ref) do
    case Repo.one(from(entry in MemoryEntry, where: entry.ref == ^ref, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:memory_not_found)

      %MemoryEntry{workspace_ref: actual} when actual != workspace_ref ->
        Repo.rollback(:memory_workspace_mismatch)

      %MemoryEntry{} = entry ->
        forget_home_visible(entry, ref, actor_ref, workspace_ref)
    end
  end

  defp forget_home_visible(entry, ref, actor_ref, workspace_ref) do
    if home_source_visible?(review_source_record(:memory, entry), actor_ref) do
      forgotten = forget_locked(ref, workspace_ref)
      dismiss_orphan_reviews("system:memory-forget", workspace_ref)
      forgotten
    else
      Repo.rollback(:memory_unauthorized)
    end
  end

  @spec list(String.t(), keyword()) :: [MemoryEntry.t()]
  def list(workspace_ref, options \\ []) do
    case list_options(workspace_ref, options) do
      {:ok, status} -> list_entries(workspace_ref, status)
      :error -> []
    end
  end

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
      workspace_ref:
        workspace_ref(episode.destination_transport, episode.destination_conversation_ref)
    })
  end

  def model_context(_episode, _repository), do: []

  @doc "Creates idempotent stale and exact-duplicate review candidates."
  @spec refresh_reviews(String.t(), pos_integer()) ::
          {:ok, %{created: non_neg_integer()}} | {:error, term()}
  def refresh_reviews(workspace_ref, stale_seconds)
      when is_integer(stale_seconds) and stale_seconds > 0 do
    with :ok <- reference(workspace_ref, :workspace_ref) do
      Repo.transaction(fn ->
        lock_review_maintenance!()
        refresh_reviews_locked(workspace_ref, stale_seconds)
      end)
      |> transaction_result()
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
    with :ok <- reference(workspace_ref, :workspace_ref),
         {:ok, status, limit} <- review_list_options(options) do
      review_query(workspace_ref, status, limit)
      |> Repo.all()
      |> Enum.map(&review_document/1)
    else
      {:error, _reason} -> []
    end
  end

  @doc "Returns only bounded reviews safe to expose in one actor's Slack App Home."
  @spec list_home_reviews(String.t(), String.t(), keyword()) :: [map()]
  def list_home_reviews(workspace_ref, actor_ref, options \\ []) do
    home_reviews(workspace_ref, actor_ref, options).items
  end

  @doc "Returns an actor-filtered App Home page and its exact pending total."
  @spec home_reviews(String.t(), String.t(), keyword()) :: %{
          items: [map()],
          total: non_neg_integer()
        }
  def home_reviews(workspace_ref, actor_ref, options \\ []) do
    with :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- reference(actor_ref, :actor_ref),
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
    with :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- reference(actor_ref, :actor_ref) do
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
    if reference_value?(ref) do
      case Repo.one(from(review in MemoryReviewItem, where: review.ref == ^ref)) do
        %MemoryReviewItem{} = review -> {:ok, review_document(review)}
        nil -> :error
      end
    else
      :error
    end
  end

  @spec resolve_review(String.t(), atom(), String.t(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve_review(review_ref, action, actor_ref, workspace_ref, replacement \\ nil) do
    with :ok <- reference(review_ref, :review_ref),
         :ok <- review_action(action),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(workspace_ref, :workspace_ref),
         {:ok, replacement} <- review_replacement(action, replacement) do
      Repo.transaction(fn ->
        lock_review_maintenance!()
        resolve_review_locked(review_ref, action, actor_ref, workspace_ref, replacement, :any)
      end)
      |> transaction_result()
    end
  end

  @doc "Resolves a review only when every affected entry is safe in the actor's App Home."
  @spec resolve_home_review(String.t(), atom(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def resolve_home_review(review_ref, action, actor_ref, workspace_ref) do
    with :ok <- reference(review_ref, :review_ref),
         :ok <- review_action(action),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(workspace_ref, :workspace_ref),
         {:ok, nil} <- review_replacement(action, nil) do
      Repo.transaction(fn ->
        lock_review_maintenance!()

        resolve_review_locked(
          review_ref,
          action,
          actor_ref,
          workspace_ref,
          nil,
          {:home_actor, actor_ref}
        )
      end)
      |> transaction_result()
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

      Repo.all(
        from(entry in MemoryEntry,
          where:
            entry.workspace_ref == ^scoped_workspace_ref and entry.scope_kind == :conversation and
              entry.scope_ref == ^conversation_ref and entry.status == :active,
          order_by: [asc: entry.ref],
          lock: "FOR UPDATE"
        )
      )
      |> Enum.each(&redact!(&1, :deleted, "channel_deleted_payload_sha256"))

      Repo.all(
        from(behavior in Behavior,
          where:
            behavior.workspace_ref == ^scoped_workspace_ref and
              behavior.scope_kind == :conversation and behavior.scope_ref == ^conversation_ref and
              behavior.status in [:active, :disabled],
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
      :ok
    else
      {:error, :memory_review_transaction_required}
    end
  end

  def delete_slack_channel_in_transaction(_workspace_ref, _channel_ref),
    do: {:error, {:invalid_memory_review, :conversation}}

  defp confirm_locked(attributes) do
    with {:ok, record, episode, turn} <- lock_offer(attributes.record_ref),
         :ok <-
           ChannelFence.authorize_in_transaction(
             episode.destination_transport,
             episode.destination_conversation_ref
           ),
         :ok <- authorize_wide_offer(record, episode),
         :ok <- delivered_from?(episode, turn, attributes.target) do
      case Repo.one(from(entry in MemoryEntry, where: entry.offer_record_id == ^record.id)) do
        %MemoryEntry{} = entry ->
          %{memory: entry, status: :duplicate}

        nil when record.status == :open ->
          create_memory(record, episode, attributes)

        nil ->
          Repo.rollback(:memory_offer_stale)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_wide_offer(
         %Record{kind: "memory_offer", payload: %{"scope" => scope}},
         %Episode{destination_transport: "slack"} = episode
       )
       when scope in ["repository", "workspace"] do
    ChannelFence.authorize_public_in_transaction(
      episode.destination_transport,
      episode.destination_conversation_ref
    )
  end

  defp authorize_wide_offer(_record, _episode), do: :ok

  defp refresh_reviews_locked(workspace_ref, stale_seconds) do
    now = database_now!()
    stale_before = DateTime.add(now, -stale_seconds, :second)

    memory_entries =
      Repo.all(
        from(entry in MemoryEntry,
          where:
            entry.workspace_ref == ^workspace_ref and entry.status == :active and
              entry.expires_at > ^now,
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
      "last_reviewed_at" => datetime(review_last_reviewed_at(source)),
      "last_used_at" => datetime(review_last_used_at(source)),
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
                 reviewed_at: database_now!(),
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
    memories =
      Repo.all(
        from(entry in MemoryEntry,
          where:
            entry.ref in ^entry_refs and entry.workspace_ref == ^workspace_ref and
              entry.status == :active and entry.expires_at > fragment("clock_timestamp()"),
          order_by: [asc: entry.ref],
          lock: "FOR UPDATE"
        )
      )
      |> Enum.map(&review_source_record(:memory, &1))

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
    now = database_now!()
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
    now = database_now!()
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

  defp dismiss_orphan_reviews(actor_ref, workspace_ref \\ nil) do
    now = database_now!()

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
    now = database_now!()

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

  defp review_source_record(type, record), do: %{record: record, type: type}

  defp review_entry_ref(%{record: record}), do: record.ref

  defp review_survivor_rank(%{record: record}) do
    {-DateTime.to_unix(record.updated_at, :microsecond), record.ref}
  end

  defp review_authorized(_review, _workspace_ref, :any), do: :ok

  defp review_authorized(review, workspace_ref, {:home_actor, actor_ref}) do
    sources = review_sources(review.entry_refs, workspace_ref, "FOR UPDATE")

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

  defp home_source_visible?(
         %{type: :memory, record: %MemoryEntry{} = entry},
         _actor_ref
       ),
       do: entry.visibility == :workspace and entry.scope_kind in [:repository, :workspace]

  defp home_source_visible?(
         %{type: :guidance, record: %Behavior{scope_kind: :operator, scope_ref: actor_ref}},
         actor_ref
       ),
       do: true

  defp home_source_visible?(%{type: :guidance, record: %Behavior{} = behavior}, _actor_ref),
    do:
      behavior.scope_kind in [:repository, :workspace] and
        behavior.payload["visibility"] == "workspace"

  defp home_source_visible?(_source, _actor_ref), do: false

  defp review_sources(entry_refs, workspace_ref, lock) do
    memory_query =
      from(entry in MemoryEntry,
        where: entry.ref in ^entry_refs and entry.workspace_ref == ^workspace_ref,
        order_by: [asc: entry.ref]
      )

    guidance_query =
      from(behavior in Behavior,
        where: behavior.ref in ^entry_refs and behavior.workspace_ref == ^workspace_ref,
        order_by: [asc: behavior.ref]
      )

    memory_query = maybe_lock_review_sources(memory_query, lock)
    guidance_query = maybe_lock_review_sources(guidance_query, lock)

    (Enum.map(Repo.all(memory_query), &review_source_record(:memory, &1)) ++
       Enum.map(Repo.all(guidance_query), &review_source_record(:guidance, &1)))
    |> Enum.sort_by(&review_entry_ref/1)
  end

  defp maybe_lock_review_sources(query, "FOR UPDATE"),
    do: from(source in query, lock: "FOR UPDATE")

  defp maybe_lock_review_sources(query, nil), do: query

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
    do: redact!(entry, status, hash_field)

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
      database_now!(),
      actor_ref,
      review.ref
    )
    |> Repo.update()
    |> review_edit_result()
  end

  defp edit_review_source(%{type: :guidance, record: behavior}, review, replacement, actor_ref) do
    now = database_now!()

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
      "last_recalled_at" => datetime(entry.last_recalled_at),
      "recall_count" => entry.recall_count,
      "scope" => Atom.to_string(entry.scope_kind),
      "scope_ref" => entry.scope_ref,
      "source_type" => "memory",
      "visibility" => Atom.to_string(entry.visibility)
    })
  end

  defp review_entry_document(%{type: :guidance, record: behavior}) do
    %{
      "confirmed_at" => DateTime.to_iso8601(behavior.confirmed_at),
      "kind" => "guidance",
      "last_recalled_at" => datetime(behavior.last_used_at),
      "memory_ref" => behavior.ref,
      "recall_count" => behavior.use_count,
      "scope" => Atom.to_string(behavior.scope_kind),
      "scope_ref" => behavior.scope_ref,
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
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  defp datetime(nil), do: nil
  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp lock_review_maintenance! do
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [@review_advisory_lock])
    :ok
  end

  defp create_memory(record, episode, attributes) do
    prepared = prepare(record.payload, episode, attributes)

    with :ok <- capacity(prepared),
         :ok <- supersede_existing(prepared),
         {:ok, entry} <- insert_entry(record, episode, attributes, prepared),
         {:ok, _record} <-
           record
           |> RecordChangeset.confirm_resource(%{
             confirmed_at: attributes.occurred_at,
             confirmed_by_actor_ref: attributes.actor_ref,
             confirmation_ref: attributes.confirmation_ref,
             status: :confirmed
           })
           |> Repo.update() do
      %{memory: entry, status: :confirmed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare(payload, episode, attributes) do
    workspace = workspace_ref(episode.destination_transport, episode.destination_conversation_ref)
    scope_kind = String.to_existing_atom(payload["scope"])

    scope_ref =
      case scope_kind do
        :conversation -> episode.destination_conversation_ref
        :repository -> payload["repository"]
        :workspace -> workspace
      end

    %{
      expires_at: expires_at(attributes.occurred_at, payload["expires_in"]),
      kind: String.to_existing_atom(payload["kind"]),
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      scope_kind: scope_kind,
      scope_ref: scope_ref,
      subject: payload["subject"],
      visibility: String.to_existing_atom(payload["visibility"]),
      workspace_ref: workspace
    }
  end

  defp capacity(prepared) do
    now = database_now!()

    existing? = existing_memory?(prepared)
    total = active_memory_count(prepared.workspace_ref, now)
    scoped = scoped_memory_count(prepared, now)

    if existing? or (total < @maximum_total and scoped < @maximum_per_scope),
      do: :ok,
      else: {:error, :memory_capacity_reached}
  end

  defp existing_memory?(prepared) do
    Repo.exists?(
      from(entry in MemoryEntry,
        where:
          entry.workspace_ref == ^prepared.workspace_ref and
            entry.scope_kind == ^prepared.scope_kind and entry.scope_ref == ^prepared.scope_ref and
            entry.kind == ^prepared.kind and entry.subject == ^prepared.subject and
            entry.status == :active
      )
    )
  end

  defp active_memory_count(workspace_ref, now) do
    Repo.aggregate(
      from(entry in MemoryEntry,
        where:
          entry.workspace_ref == ^workspace_ref and entry.status == :active and
            entry.expires_at > ^now
      ),
      :count
    )
  end

  defp scoped_memory_count(prepared, now) do
    Repo.aggregate(
      from(entry in MemoryEntry,
        where:
          entry.workspace_ref == ^prepared.workspace_ref and
            entry.scope_kind == ^prepared.scope_kind and entry.scope_ref == ^prepared.scope_ref and
            entry.status == :active and entry.expires_at > ^now
      ),
      :count
    )
  end

  defp list_options(workspace_ref, options) do
    if Keyword.keyword?(options) do
      status = Keyword.get(options, :status)

      if reference_value?(workspace_ref) and
           (is_nil(status) or status in [:active, :superseded, :deleted, :expired]) and
           Keyword.keys(options) -- [:status] == [],
         do: {:ok, status},
         else: :error
    else
      :error
    end
  end

  defp list_entries(workspace_ref, status) do
    query =
      from(entry in MemoryEntry,
        where: entry.workspace_ref == ^workspace_ref,
        order_by: [desc: entry.updated_at, desc: entry.id],
        limit: 1_000
      )

    query = if status, do: from(entry in query, where: entry.status == ^status), else: query
    Repo.all(query)
  end

  defp recall_entries(context, limit) do
    Repo.transaction(fn -> recall_locked(context, limit) end)
    |> case do
      {:ok, entries} -> entries
      {:error, _reason} -> []
    end
  end

  defp supersede_existing(prepared) do
    Repo.all(
      from(entry in MemoryEntry,
        where:
          entry.workspace_ref == ^prepared.workspace_ref and
            entry.scope_kind == ^prepared.scope_kind and entry.scope_ref == ^prepared.scope_ref and
            entry.kind == ^prepared.kind and entry.subject == ^prepared.subject and
            entry.status == :active,
        lock: "FOR UPDATE"
      )
    )
    |> Enum.each(&redact!(&1, :superseded, "replaced_payload_sha256"))

    :ok
  end

  defp insert_entry(record, episode, attributes, prepared) do
    id = Ecto.UUID.generate()

    prepared
    |> Map.merge(%{
      confirmation_ref: attributes.confirmation_ref,
      confirmed_at: attributes.occurred_at,
      confirmed_by_actor_ref: attributes.actor_ref,
      id: id,
      offer_record_id: record.id,
      ref: "memory:#{id}",
      source_conversation_ref: episode.destination_conversation_ref,
      source_message_ref: attributes.target.message_ref,
      source_thread_ref: episode.destination_thread_ref,
      source_transport: episode.destination_transport,
      status: :active
    })
    |> MemoryEntryChangeset.insert()
    |> Repo.insert()
    |> case do
      {:ok, entry} -> {:ok, entry}
      {:error, changeset} -> {:error, {:memory_persistence_failed, changeset.errors}}
    end
  end

  defp forget_locked(ref, workspace_ref) do
    case Repo.one(from(entry in MemoryEntry, where: entry.ref == ^ref, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:memory_not_found)

      %MemoryEntry{workspace_ref: actual}
      when not is_nil(workspace_ref) and actual != workspace_ref ->
        Repo.rollback(:memory_workspace_mismatch)

      %MemoryEntry{status: :deleted} = entry ->
        entry

      %MemoryEntry{status: status} when status in [:expired, :superseded] ->
        Repo.rollback(:memory_terminal)

      %MemoryEntry{} = entry ->
        redact!(entry, :deleted, "forgotten_payload_sha256")
    end
  end

  defp redact!(entry, status, hash_field) do
    payload = %{hash_field => entry.payload_fingerprint}
    fingerprint = CanonicalJSON.digest(payload)

    entry
    |> MemoryEntryChangeset.redact(status, payload, fingerprint)
    |> Repo.update!()
  end

  defp recall_locked(context, limit) do
    entries =
      visible_entries(context)
      |> Enum.filter(&visible?(&1, context))
      |> Enum.sort_by(&rank/1)
      |> Enum.take(limit)

    account_memory(entries)
  end

  defp search_locked(context, query, scope, limit) do
    query = String.downcase(query)

    entries =
      visible_entries(context)
      |> Enum.filter(fn entry ->
        visible?(entry, context) and memory_search_scope?(entry, scope, context) and
          entry
          |> document()
          |> CanonicalJSON.encode!()
          |> String.downcase()
          |> String.contains?(query)
      end)
      |> Enum.sort_by(&rank/1)
      |> Enum.take(limit)

    account_memory(entries)
  end

  defp visible_entries(context) do
    now = database_now!()

    Repo.all(
      from(entry in MemoryEntry,
        where:
          entry.workspace_ref == ^context.workspace_ref and entry.status == :active and
            entry.expires_at > ^now,
        order_by: [desc: entry.updated_at, desc: entry.id],
        limit: 1_000
      )
    )
  end

  defp account_memory(entries) do
    now = database_now!()

    ids = Enum.map(entries, & &1.id)

    if ids != [] do
      Repo.update_all(
        from(entry in MemoryEntry, where: entry.id in ^ids),
        inc: [recall_count: 1],
        set: [last_recalled_at: now, updated_at: now]
      )
    end

    Enum.map(entries, &document/1)
  end

  defp memory_search_scope?(
         %MemoryEntry{scope_kind: :conversation, scope_ref: ref},
         "current_channel",
         context
       ),
       do: ref == context.conversation_ref

  defp memory_search_scope?(
         %MemoryEntry{scope_kind: :repository, scope_ref: ref},
         "repository",
         context
       ),
       do: ref == context.repository

  defp memory_search_scope?(
         %MemoryEntry{scope_kind: :workspace, scope_ref: ref},
         "workspace",
         context
       ),
       do: ref == context.workspace_ref

  defp memory_search_scope?(_entry, _scope, _context), do: false

  defp visible?(%MemoryEntry{visibility: :conversation} = entry, context),
    do: entry.source_conversation_ref == context.conversation_ref and scoped?(entry, context)

  defp visible?(%MemoryEntry{visibility: :workspace} = entry, context),
    do: scoped?(entry, context)

  defp scoped?(%MemoryEntry{scope_kind: :conversation, scope_ref: ref}, context),
    do: ref == context.conversation_ref

  defp scoped?(%MemoryEntry{scope_kind: :repository, scope_ref: ref}, context),
    do: ref == context.repository

  defp scoped?(%MemoryEntry{scope_kind: :workspace, scope_ref: ref}, context),
    do: ref == context.workspace_ref

  defp rank(entry) do
    scope_rank =
      case entry.scope_kind do
        :conversation -> 0
        :repository -> 1
        :workspace -> 2
      end

    visibility_rank = if entry.visibility == :conversation, do: 0, else: 1
    recent = -DateTime.to_unix(entry.updated_at, :microsecond)

    {scope_rank, visibility_rank, recent, entry.ref}
  end

  defp document(entry) do
    %{
      "confirmed_at" => DateTime.to_iso8601(entry.confirmed_at),
      "expires_at" => DateTime.to_iso8601(entry.expires_at),
      "kind" => Atom.to_string(entry.kind),
      "memory_ref" => entry.ref,
      "scope" => Atom.to_string(entry.scope_kind),
      "source" => %{
        "conversation_ref" => entry.source_conversation_ref,
        "message_ref" => entry.source_message_ref,
        "thread_ref" => entry.source_thread_ref,
        "transport" => entry.source_transport
      },
      "subject" => entry.subject,
      "value" => entry.payload["value"],
      "visibility" => Atom.to_string(entry.visibility)
    }
    |> put_edit_provenance(entry)
  end

  defp put_edit_provenance(document, %MemoryEntry{edited_at: %DateTime{} = edited_at} = entry) do
    Map.put(document, "edit", %{
      "actor_ref" => entry.edited_by_actor_ref,
      "edited_at" => DateTime.to_iso8601(edited_at),
      "review_ref" => entry.edit_review_ref
    })
  end

  defp put_edit_provenance(document, _entry), do: document

  defp lock_offer(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where: record.ref == ^record_ref and record.kind == "memory_offer",
        select: {record, episode, turn},
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :memory_offer_not_found}
      {record, episode, turn} -> {:ok, record, episode, turn}
    end
  end

  defp delivered_from?(episode, %Turn{status: :settled, external_receipt: receipt}, target)
       when is_map(receipt) do
    expected = %{
      conversation_ref: episode.destination_conversation_ref,
      message_ref: receipt["message_ref"],
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }

    if expected == target,
      do: :ok,
      else: {:error, :memory_offer_delivery_mismatch}
  end

  defp delivered_from?(_episode, _turn, _target), do: {:error, :memory_offer_not_delivered}

  defp retrieval_context(context) do
    fields = [:conversation_ref, :repository, :workspace_ref]

    if Map.keys(context) |> Enum.sort() == Enum.sort(fields) and
         reference_value?(context.conversation_ref) and reference_value?(context.workspace_ref) and
         (is_nil(context.repository) or reference_value?(context.repository)) do
      {:ok, context}
    else
      {:error, :invalid_memory_context}
    end
  end

  defp workspace_ref("slack", conversation_ref) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", workspace_ref, _channel_ref] -> "slack:#{workspace_ref}"
      _invalid -> conversation_ref
    end
  end

  defp workspace_ref("github", conversation_ref) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["github", binding_ref, _rest] -> "github:#{binding_ref}"
      _invalid -> conversation_ref
    end
  end

  defp workspace_ref(_transport, conversation_ref), do: conversation_ref

  defp expires_at(confirmed_at, "7d"), do: DateTime.add(confirmed_at, 7, :day)
  defp expires_at(confirmed_at, "30d"), do: DateTime.add(confirmed_at, 30, :day)
  defp expires_at(confirmed_at, "90d"), do: DateTime.add(confirmed_at, 90, :day)
  defp expires_at(confirmed_at, "365d"), do: DateTime.add(confirmed_at, 365, :day)

  defp confirmation_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> confirmation_attributes(),
       else: {:error, {:invalid_memory_confirmation, :fields}}
  end

  defp confirmation_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@confirmation_fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_memory_confirmation, :fields}}
  end

  defp confirmation_attributes(_attributes),
    do: {:error, {:invalid_memory_confirmation, :fields}}

  defp target(%{} = target) do
    if Map.keys(target) |> Enum.sort() == Enum.sort(@target_fields) do
      with :ok <- reference(target.transport, :transport),
           :ok <- reference(target.conversation_ref, :conversation_ref),
           :ok <- optional_reference(target.thread_ref, :thread_ref),
           :ok <- reference(target.message_ref, :message_ref) do
        {:ok, target}
      end
    else
      {:error, {:invalid_memory_confirmation, :target}}
    end
  end

  defp target(_target), do: {:error, {:invalid_memory_confirmation, :target}}

  defp utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      {microsecond, _precision} = value.microsecond
      {:ok, %{value | microsecond: {microsecond, 6}}}
    else
      {:error, {:invalid_memory_confirmation, :occurred_at}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_memory_confirmation, :occurred_at}}

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if reference_value?(value),
      do: :ok,
      else: {:error, {:invalid_memory_confirmation, field}}
  end

  defp reference_value?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  defp database_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
