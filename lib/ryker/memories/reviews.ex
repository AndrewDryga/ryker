defmodule Ryker.Memories.Reviews do
  @moduledoc """
  The stale-fact, stale-guidance and duplicate-guidance review queue.

  Reviews are idempotent candidates keyed by a digest of their sources, opened
  one workspace at a time (`refresh_reviews/2`); a person keeps, merges,
  edits or forgets them. A write that ends, replaces or changes a fact or
  guidance holds the review lock (`lock_review_maintenance!/0`) and dismisses
  the reviews of its workspace it left with nothing to decide, so a review
  never names an entry a concurrent write is replacing. Recall, expiry and
  retention change entries without the lock; the next refresh dismisses the
  reviews they made moot, and resolving one re-checks its entries under their
  row locks.

  Facts never form duplicates: one scope holds one active fact per subject
  (`operational_memory_active_identity`), and the review grouped facts by a
  key that contains it.
  """
  alias Ryker.AdvisoryLock
  alias Ryker.Behaviors
  alias Ryker.CanonicalJSON
  alias Ryker.Memories
  alias Ryker.Memories.Forgetting
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Memories.MemoryReviewItem
  alias Ryker.Reference
  alias Ryker.Repo

  @maximum_reviews 100
  @maximum_home_review_entries 8
  @review_advisory_lock 7_152_019_552_843_112

  @doc """
  Opens the stale and duplicate reviews of one workspace and dismisses the
  ones its entries left with nothing to decide, in one short transaction.
  """
  @spec refresh_reviews(String.t(), pos_integer()) ::
          {:ok, %{created: non_neg_integer()}} | {:error, term()}
  def refresh_reviews(workspace_ref, stale_seconds)
      when is_integer(stale_seconds) and stale_seconds > 0 do
    with :ok <- Reference.check(workspace_ref, :workspace_ref, :invalid_memory_confirmation) do
      Repo.transaction(fn ->
        lock_review_maintenance!()
        refresh_reviews_locked(workspace_ref, stale_seconds)
      end)
    end
  end

  def refresh_reviews(_workspace_ref, _stale_seconds),
    do: {:error, {:invalid_memory_review, :stale_seconds}}

  @doc """
  Refreshes every workspace with an active fact, active guidance or a pending
  review, each in its own transaction (`refresh_reviews/2`), and answers how
  many reviews it opened. Retention refreshed them inside its pruning
  transaction, and so held the review lock through compaction and pruning:
  every memory write waited out the whole phase, and saving an answer, which
  waits one second for its locks, failed (2026-10-04 review).
  """
  @spec refresh_all_reviews(pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def refresh_all_reviews(stale_seconds) when is_integer(stale_seconds) and stale_seconds > 0 do
    {created, failed} =
      Enum.reduce(review_workspaces(), {0, []}, fn workspace_ref, {created, failed} ->
        case refresh_reviews(workspace_ref, stale_seconds) do
          {:ok, %{created: count}} -> {created + count, failed}
          {:error, reason} -> {created, [{workspace_ref, reason} | failed]}
        end
      end)

    if failed == [],
      do: {:ok, created},
      else: {:error, {:memory_reviews_not_refreshed, Enum.reverse(failed)}}
  end

  def refresh_all_reviews(_stale_seconds),
    do: {:error, {:invalid_memory_review, :stale_seconds}}

  # A workspace whose every entry ended or expired still has its pending
  # reviews dismissed.
  defp review_workspaces do
    facts =
      MemoryEntry.Query.active()
      |> MemoryEntry.Query.select_distinct_workspace_refs()
      |> Repo.all()

    guidance =
      Behaviors.Behavior.Query.by_kind(:guidance)
      |> Behaviors.Behavior.Query.by_status(:active)
      |> Behaviors.Behavior.Query.select_distinct_workspace_refs()
      |> Repo.all()

    reviews =
      MemoryReviewItem.Query.pending()
      |> MemoryReviewItem.Query.select_distinct_workspace_refs()
      |> Repo.all()

    Enum.sort(Enum.uniq(facts ++ guidance ++ reviews))
  end

  @doc """
  Returns an actor-filtered App Home page and its exact pending total. The
  total counts only reviews App Home can show: it counted the ones naming more
  entries than a page holds too (2026-10-04 review).
  """
  @spec home_reviews(String.t(), String.t(), keyword()) :: %{
          items: [map()],
          total: non_neg_integer()
        }
  def home_reviews(workspace_ref, actor_ref, options \\ []) do
    with :ok <- Reference.check(workspace_ref, :workspace_ref, :invalid_memory_confirmation),
         :ok <- Reference.check(actor_ref, :actor_ref, :invalid_memory_confirmation),
         {:ok, status, limit} <- review_list_options(options) do
      query = home_review_query(workspace_ref, actor_ref, status)

      items =
        query
        |> MemoryReviewItem.Query.ordered_by_oldest()
        |> MemoryReviewItem.Query.limit_to(limit)
        |> Repo.all()
        |> Enum.map(&review_document/1)

      %{items: items, total: Repo.aggregate(query, :count, :id)}
    else
      {:error, _reason} -> %{items: [], total: 0}
    end
  end

  @spec pending_reviews(pos_integer()) :: [map()]
  def pending_reviews(limit \\ 20)

  def pending_reviews(limit) when is_integer(limit) and limit in 1..@maximum_reviews do
    MemoryReviewItem.Query.pending()
    |> MemoryReviewItem.Query.ordered_by_oldest()
    |> MemoryReviewItem.Query.limit_to(limit)
    |> Repo.all()
    |> Enum.map(&review_document/1)
  end

  def pending_reviews(_limit), do: []

  @doc "How many reviews are pending."
  @spec pending_review_count() :: non_neg_integer()
  def pending_review_count,
    do: Repo.aggregate(MemoryReviewItem.Query.pending(), :count)

  @doc "One pending review, by reference, or nil."
  @spec pending_review(String.t()) :: map() | nil
  def pending_review(review_ref) when is_binary(review_ref) do
    pending = review_ref |> MemoryReviewItem.Query.by_ref() |> MemoryReviewItem.Query.pending()

    case Repo.one(pending) do
      nil -> nil
      review -> review_document(review)
    end
  end

  @doc "Fetches one pending review only when every entry is safe for this App Home actor."
  @spec fetch_home_review(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :memory_review_not_found}
  def fetch_home_review(review_ref, workspace_ref, actor_ref) do
    with :ok <- Reference.check(review_ref, :review_ref, :invalid_memory_confirmation),
         :ok <- Reference.check(workspace_ref, :workspace_ref, :invalid_memory_confirmation),
         :ok <- Reference.check(actor_ref, :actor_ref, :invalid_memory_confirmation),
         %MemoryReviewItem{} = review <- pending_home_review(review_ref, workspace_ref, actor_ref) do
      {:ok, review_document(review)}
    else
      _unavailable -> {:error, :memory_review_not_found}
    end
  end

  defp pending_home_review(review_ref, workspace_ref, actor_ref) do
    workspace_ref
    |> home_review_query(actor_ref, :pending)
    |> MemoryReviewItem.Query.by_ref(review_ref)
    |> Repo.one()
  end

  @spec resolve_review(String.t(), atom(), String.t(), String.t(), map() | nil) ::
          {:ok, map()} | {:error, term()}
  def resolve_review(review_ref, action, actor_ref, workspace_ref, replacement \\ nil) do
    with :ok <- Reference.check(review_ref, :review_ref, :invalid_memory_confirmation),
         :ok <- review_action(action),
         :ok <- Reference.check(actor_ref, :actor_ref, :invalid_memory_confirmation),
         :ok <- Reference.check(workspace_ref, :workspace_ref, :invalid_memory_confirmation),
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
    with :ok <- Reference.check(review_ref, :review_ref, :invalid_memory_confirmation),
         :ok <- review_action(action),
         :ok <- Reference.check(actor_ref, :actor_ref, :invalid_memory_confirmation),
         :ok <- Reference.check(workspace_ref, :workspace_ref, :invalid_memory_confirmation),
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
      # One already ended keeps its ending but loses its words too; only live
      # rows were redacted, so a rule replaced or deleted before the channel
      # went kept its text past it (2026-10-04 review).
      scoped_workspace_ref
      |> Behaviors.Behavior.Query.bound_to_conversation(conversation_ref)
      |> Behaviors.Behavior.Query.ordered_by_ref()
      |> Behaviors.Behavior.Query.lock_for_update()
      |> Repo.all()
      |> Enum.reject(&Behaviors.redacted?(&1.payload))
      |> Enum.each(&redact_channel_behavior!/1)

      dismiss_orphan_reviews("system:slack-channel-deletion", scoped_workspace_ref)
      dismiss_orphan_reviews("system:slack-channel-deletion", "installation")
      :ok
    else
      {:error, :memory_review_transaction_required}
    end
  end

  def delete_slack_channel_in_transaction(_workspace_ref, _channel_ref),
    do: {:error, {:invalid_memory_review, :conversation}}

  defp delete_channel_facts(workspace_ref, conversation_ref) do
    workspace_ref
    |> MemoryEntry.Query.bound_to_conversation(conversation_ref)
    |> MemoryEntry.Query.ordered_by_ref()
    |> MemoryEntry.Query.lock_for_update()
    |> Repo.all()
    |> Enum.each(&Memories.redact!(&1, :deleted, "channel_deleted_payload_sha256"))
  end

  defp refresh_reviews_locked(workspace_ref, stale_seconds) do
    now = Repo.now!()
    stale_before = DateTime.add(now, -stale_seconds, :second)

    memory_entries =
      workspace_ref
      |> MemoryEntry.Query.by_workspace()
      |> MemoryEntry.Query.active()
      |> MemoryEntry.Query.unexpired_at(now)
      |> MemoryEntry.Query.ordered_by_least_recently_updated()
      |> MemoryEntry.Query.limit_to(1_000)
      |> Repo.all()

    guidance =
      workspace_ref
      |> Behaviors.Behavior.Query.by_workspace()
      |> Behaviors.Behavior.Query.by_kind(:guidance)
      |> Behaviors.Behavior.Query.by_status(:active)
      |> Behaviors.Behavior.Query.unexpired_at(now)
      |> Behaviors.Behavior.Query.ordered_by_least_recently_updated()
      |> Behaviors.Behavior.Query.limit_to(500)
      |> Repo.all()

    guidance = Enum.map(guidance, &review_source_record(:guidance, &1))
    sources = Enum.map(memory_entries, &review_source_record(:memory, &1)) ++ guidance

    stale =
      Enum.filter(sources, &stale_review_source?(&1, stale_before))

    duplicate_groups =
      guidance
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

    if Repo.exists?(MemoryReviewItem.Query.by_source_digest(digest)) do
      false
    else
      id = Repo.generate_id()

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
        |> MemoryReviewItem.Changeset.insert()

      changeset |> Repo.insert() |> review_inserted()
    end
  end

  defp review_inserted({:ok, review}) do
    Memories.broadcast_memory_updated(review.id)
    true
  end

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

  # A review naming more entries than an App Home page holds is resolved in
  # the console.
  defp home_review_query(workspace_ref, actor_ref, status) do
    workspace_ref
    |> MemoryReviewItem.Query.by_workspace()
    |> MemoryReviewItem.Query.home_visible(workspace_ref, actor_ref)
    |> MemoryReviewItem.Query.by_entry_count_at_most(@maximum_home_review_entries)
    |> MemoryReviewItem.Query.by_status(status)
  end

  defp resolve_review_locked(
         review_ref,
         action,
         actor_ref,
         workspace_ref,
         replacement,
         authorization
       ) do
    locked =
      review_ref |> MemoryReviewItem.Query.by_ref() |> MemoryReviewItem.Query.lock_for_update()

    case Repo.one(locked) do
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
             changeset =
               MemoryReviewItem.Changeset.resolve(review, %{
                 action: action,
                 replacement: review_audit_replacement(action, replacement),
                 reviewed_at: Repo.now!(),
                 reviewed_by_actor_ref: actor_ref,
                 status: review_status(action)
               }),
             {:ok, review} <- Repo.update(changeset) do
          Memories.broadcast_memory_updated(review.id)
          dismiss_superseded_reviews(review, entries, action, actor_ref)
          dismiss_orphan_reviews(actor_ref, workspace_ref)

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
      entry_refs
      |> current_facts(workspace_ref)
      |> MemoryEntry.Query.lock_for_update()
      |> Repo.all()
      |> Enum.map(&review_source_record(:memory, &1))

    guidance =
      entry_refs
      |> current_guidance(workspace_ref)
      |> Behaviors.Behavior.Query.lock_for_update()
      |> Repo.all()
      |> Enum.map(&review_source_record(:guidance, &1))

    Enum.sort_by(memories ++ guidance, &review_entry_ref/1)
  end

  # The entries a review may still decide about: active and unexpired.
  defp current_facts(entry_refs, workspace_ref) do
    entry_refs
    |> MemoryEntry.Query.by_refs()
    |> MemoryEntry.Query.by_workspace(workspace_ref)
    |> MemoryEntry.Query.active()
    |> MemoryEntry.Query.unexpired()
    |> MemoryEntry.Query.ordered_by_ref()
  end

  defp current_guidance(entry_refs, workspace_ref) do
    entry_refs
    |> Behaviors.Behavior.Query.by_refs()
    |> Behaviors.Behavior.Query.by_workspace(workspace_ref)
    |> Behaviors.Behavior.Query.by_kind(:guidance)
    |> Behaviors.Behavior.Query.by_status(:active)
    |> Behaviors.Behavior.Query.unexpired()
    |> Behaviors.Behavior.Query.ordered_by_ref()
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

  defp apply_review_action(_review, entries, :keep, _replacement, _actor_ref) do
    now = Repo.now!()
    Enum.each(entries, &review_source!(&1, now))
    :ok
  end

  # What learning took from a forgotten fact's message goes with it, as when
  # the fact is forgotten directly; this path only redacted the fact
  # (2026-10-04 review).
  defp apply_review_action(_review, entries, :forget, _replacement, _actor_ref) do
    Enum.each(entries, fn source ->
      redact_review_source!(source, :deleted, "forgotten_payload_sha256")
      forget_learning(source)
    end)

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

  @doc """
  Dismisses the pending reviews of `workspace_ref` that a change left with
  nothing to decide: an entry ended, expired or changed since the review
  opened. Called with the review lock held. It reads the reviews and their
  entries in two queries; it took two locking queries per pending review in
  every workspace, on every memory write (2026-10-04 review). Entries are
  read, not locked: a writer that ends or changes one holds the review lock,
  recall only ever makes a review moot, and resolving a review locks its
  entries again.
  """
  @spec dismiss_orphan_reviews(String.t(), String.t()) :: :ok
  def dismiss_orphan_reviews(actor_ref, workspace_ref) do
    reviews =
      workspace_ref
      |> MemoryReviewItem.Query.by_workspace()
      |> MemoryReviewItem.Query.pending()
      |> MemoryReviewItem.Query.ordered_by_oldest()
      |> MemoryReviewItem.Query.lock_for_update()
      |> Repo.all()

    refs = reviews |> Enum.flat_map(& &1.entry_refs) |> Enum.uniq()

    current =
      Map.new(
        Enum.map(Repo.all(current_facts(refs, workspace_ref)), &review_source_record(:memory, &1)) ++
          Enum.map(
            Repo.all(current_guidance(refs, workspace_ref)),
            &review_source_record(:guidance, &1)
          ),
        &{review_entry_ref(&1), &1}
      )

    now = Repo.now!()

    reviews
    |> Enum.reject(fn review ->
      entries = review.entry_refs |> Enum.sort() |> Enum.flat_map(&List.wrap(current[&1]))
      review_entries_current(review, entries) == :ok
    end)
    |> Enum.each(&dismiss!(&1, actor_ref, now))
  end

  defp dismiss!(review, actor_ref, now) do
    review
    |> MemoryReviewItem.Changeset.resolve(%{
      action: :dismiss,
      replacement: nil,
      reviewed_at: now,
      reviewed_by_actor_ref: actor_ref,
      status: :dismissed
    })
    |> Repo.update!()

    Memories.broadcast_memory_updated(review.id)
  end

  defp dismiss_superseded_reviews(_review, _entries, :keep, _actor_ref), do: :ok

  defp dismiss_superseded_reviews(review, entries, _action, actor_ref) do
    refs = MapSet.new(entries, &review_entry_ref/1)
    now = Repo.now!()

    review.workspace_ref
    |> MemoryReviewItem.Query.by_workspace()
    |> MemoryReviewItem.Query.pending()
    |> MemoryReviewItem.Query.excluding_id(review.id)
    |> MemoryReviewItem.Query.lock_for_update()
    |> Repo.all()
    |> Enum.reject(&(&1.entry_refs |> MapSet.new() |> MapSet.disjoint?(refs)))
    |> Enum.each(&dismiss!(&1, actor_ref, now))
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
      entry_refs
      |> MemoryEntry.Query.by_refs()
      |> MemoryEntry.Query.ordered_by_ref()
      |> Repo.all()
      |> Enum.map(&review_source_record(:memory, &1))

    guidance =
      entry_refs
      |> Behaviors.Behavior.Query.by_refs()
      |> Behaviors.Behavior.Query.ordered_by_ref()
      |> Repo.all()
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
        %{
          type: :guidance,
          record: %Behaviors.Behavior{scope_kind: :operator, scope_ref: actor_ref}
        },
        actor_ref
      ),
      do: true

  def home_source_visible?(
        %{type: :guidance, record: %Behaviors.Behavior{} = behavior},
        _actor_ref
      ) do
    behavior.scope_kind in [:repository, :workspace] and
      behavior.payload["visibility"] == "workspace"
  end

  def home_source_visible?(_source, _actor_ref), do: false

  defp review_sources(entry_refs, workspace_ref) do
    memory_query =
      entry_refs
      |> MemoryEntry.Query.by_refs()
      |> MemoryEntry.Query.by_workspace(workspace_ref)
      |> MemoryEntry.Query.ordered_by_ref()
      |> MemoryEntry.Query.lock_for_update()

    guidance_query =
      entry_refs
      |> Behaviors.Behavior.Query.by_refs()
      |> Behaviors.Behavior.Query.by_workspace(workspace_ref)
      |> Behaviors.Behavior.Query.ordered_by_ref()
      |> Behaviors.Behavior.Query.lock_for_update()

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

  defp duplicate_identity(%{type: :guidance, record: behavior}) do
    {behavior.scope_kind, behavior.scope_ref, behavior.payload["visibility"],
     behavior.payload["text"]}
  end

  defp review_source!(%{type: :memory, record: entry}, now) do
    Memories.broadcast_memory_updated(entry.id)
    entry |> MemoryEntry.Changeset.review(now) |> Repo.update!()
  end

  defp review_source!(%{type: :guidance, record: behavior}, now) do
    Behaviors.broadcast_behavior_updated(behavior.id)

    behavior
    |> Behaviors.Behavior.Changeset.update(%{last_reviewed_at: now})
    |> Repo.update!()
  end

  defp redact_review_source!(%{type: :memory, record: entry}, status, hash_field),
    do: Memories.redact!(entry, status, hash_field)

  defp redact_review_source!(%{type: :guidance, record: behavior}, status, hash_field),
    do: Behaviors.redact!(behavior, status, hash_field)

  defp redact_channel_behavior!(%Behaviors.Behavior{status: status} = behavior) do
    ended = if status in [:active, :disabled], do: :deleted, else: status
    Behaviors.redact!(behavior, ended, "channel_deleted_payload_sha256")
  end

  defp forget_learning(%{type: :memory, record: entry}),
    do: Forgetting.forget_fact_in_transaction(entry)

  defp forget_learning(_guidance), do: :ok

  defp edit_review_source(%{type: :memory, record: entry}, review, replacement, actor_ref) do
    payload =
      entry.payload
      |> Map.put("subject", replacement["subject"])
      |> Map.put("value", replacement["value"])

    fingerprint = CanonicalJSON.digest(payload)

    entry
    |> MemoryEntry.Changeset.edit(
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
    |> Behaviors.Behavior.Changeset.update(%{
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

  defp review_edit_result({:ok, %Behaviors.Behavior{id: id}}),
    do: Behaviors.broadcast_behavior_updated(id)

  defp review_edit_result({:ok, %MemoryEntry{id: id}}), do: Memories.broadcast_memory_updated(id)

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

  defp review_action(action) when action in [:keep, :merge, :edit, :forget], do: :ok
  defp review_action(_action), do: {:error, {:invalid_memory_review, :action}}

  defp review_replacement(:edit, %{"subject" => subject, "value" => value} = replacement)
       when map_size(replacement) == 2 do
    if Reference.text?(subject, 120) and Reference.text?(value, 4_000),
      do: {:ok, replacement},
      else: {:error, {:invalid_memory_review, :replacement}}
  end

  defp review_replacement(:edit, _replacement),
    do: {:error, {:invalid_memory_review, :replacement}}

  defp review_replacement(_action, nil), do: {:ok, nil}

  defp review_replacement(_action, _replacement),
    do: {:error, {:invalid_memory_review, :replacement}}

  defp review_status(action) when action in [:keep], do: :kept
  defp review_status(action) when action in [:merge, :edit, :forget], do: :applied

  @doc false
  def lock_review_maintenance!, do: AdvisoryLock.hold!(@review_advisory_lock)
end
