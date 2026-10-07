defmodule Ryker.Memories do
  @moduledoc """
  Operator-confirmed operational memory with exact scope and provenance.

  Memory is a potentially stale model hint. It cannot start work, satisfy an
  evidence requirement, choose a repository policy, or authorize an effect.
  Replacement and forgetting erase the stored value while retaining only its
  digest and lifecycle identity.

  This module owns the entry lifecycle: confirming an offer or a reusable
  answer, forgetting, revoking on source edits, and listing. Reading memory
  for a model context lives in `Ryker.Memories.Recall`; the stale and
  duplicate review queue lives in `Ryker.Memories.Reviews`. The
  delegates below are the memories context API for callers outside the state
  layer (Slack, the control plane, work submission), not a compatibility shim:
  callers inside the state, retention, and tooling layers call the owning
  module directly.

  A fact confirmed, edited, reviewed, superseded or forgotten, a review item
  opened or resolved, and a remembered case captured or removed are announced
  after the outermost commit (`subscribe_memories/0`).
  """

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.Episode
  alias Ryker.Episodes.Scope
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Memories.Forgetting
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Memories.Recall
  alias Ryker.Memories.Reviews
  alias Ryker.Records
  alias Ryker.Records.CardDelivery
  alias Ryker.Records.Record
  alias Ryker.Records.Response
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.RoutingExamples
  alias Ryker.Slack.ChannelFence
  alias Ryker.StateTools.Binding
  alias Ryker.UTCDateTime

  @confirmation_fields [:actor_ref, :confirmation_ref, :occurred_at, :record_ref, :target]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]
  @maximum_total 1_000
  @maximum_per_scope 100

  @spec confirm(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def confirm(attributes) do
    with {:ok, attributes} <- confirmation_attributes(attributes),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.confirmation_ref, :confirmation_ref),
         :ok <- reference(attributes.record_ref, :record_ref),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        # Taken before the offer and channel locks, the order ingress uses;
        # superseding the previous fact closes the reviews that named it.
        Reviews.lock_review_maintenance!()
        confirm_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
    end
  end

  @doc "Save only the normalized answer to an explicitly reusable, delivered question."
  def confirm_answer(binding, record_ref, value, authorize)
      when is_binary(record_ref) and is_binary(value) and is_function(authorize, 1) do
    if Reference.valid?(value, 4_000) do
      Repo.transaction(fn -> confirm_answer_locked(binding, record_ref, value, authorize) end)
    else
      {:error, :invalid_answer_memory}
    end
  end

  def confirm_answer(_binding, _record_ref, _value, _authorize),
    do: {:error, :answer_memory_unauthorized}

  # Each refusal names its reason. They all read answer_memory_unauthorized,
  # so the model could not tell a question it named wrongly from an answer it
  # may not save (2026-10-04 review).
  defp confirm_answer_locked(binding, record_ref, value, authorize) do
    with {:ok, current} <- Binding.lock_current(binding),
         :ok <- live(current.episode),
         :ok <- Reviews.lock_review_maintenance!(),
         {:ok, record, response, entry} <- answer_confirmation(current, record_ref),
         :ok <- answerer(authorize, entry),
         {:ok, intent} <- remember_intent(record),
         :ok <- unrevised(entry),
         :ok <- said(value, answer_text(response, entry)) do
      save_answer(record, response, entry, intent, value)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp live(%{execution_mode: :live}), do: :ok
  defp live(_episode), do: {:error, :state_record_shadow_forbidden}

  defp answerer(authorize, entry),
    do: if(authorize.(entry) == true, do: :ok, else: {:error, :answer_memory_unauthorized})

  defp remember_intent(%Record{payload: %{"remember" => %{} = intent}}), do: {:ok, intent}
  defp remember_intent(_record), do: {:error, :answer_memory_not_requested}

  defp unrevised(entry),
    do: if(answer_revised?(entry), do: {:error, :answer_memory_revised}, else: :ok)

  # The saved fact is credited to the person who answered, so the value may
  # trim their answer to the fact and never add to it: every word of it is a
  # word of their choice or reply. The model's value was saved unchecked
  # (2026-10-04 review).
  defp said(value, answer) do
    words = words(value)

    if words != [] and MapSet.subset?(MapSet.new(words), MapSet.new(words(answer))),
      do: :ok,
      else: {:error, :answer_memory_not_in_answer}
  end

  defp answer_text(%Response{choice: choice}, _entry) when is_binary(choice), do: choice
  defp answer_text(_response, %Entry{content: %{"text" => text}}) when is_binary(text), do: text
  defp answer_text(_response, _entry), do: ""

  defp words(text),
    do: ~r/[\p{L}\p{N}]+/u |> Regex.scan(String.downcase(text)) |> List.flatten()

  defp answer_confirmation(binding, record_ref) do
    record_ref
    |> Record.Query.answered_question(binding.episode.id)
    |> Repo.one()
    |> answered()
  end

  defp answered({record, response, entry}), do: {:ok, record, response, entry}
  defp answered(nil), do: {:error, :answer_memory_question_not_found}

  # A newer revision that took the answer's words back; a link preview
  # arriving as an edit kept the answer from being saved (2026-10-04 review).
  defp answer_revised?(entry) do
    entry
    |> Entry.Query.later_revisions_of()
    |> Repo.all()
    |> Enum.any?(&RoutingExamples.takes_back_words?/1)
  end

  @doc "Explicit source changes revoke answer-confirmed facts; ordinary transcript TTL does not."
  def revoke_answer_source_in_transaction(
        %Entry{event_kind: kind, source_item_ref: source_ref} = entry
      )
      when kind in [:edit, :delete] and is_binary(source_ref) do
    if Repo.in_transaction?() do
      # Ingress takes this before observation/channel locks; saving an answer uses
      # the same review lock before checking its original revision and inserting.
      Reviews.lock_review_maintenance!()

      entry.destination_transport
      |> MemoryEntry.Query.answered_before_revision(
        entry.destination_conversation_ref,
        source_ref,
        entry.revision
      )
      |> MemoryEntry.Query.lock_for_update()
      |> Repo.all()
      |> Enum.each(&redact!(&1, :deleted, "answer_revised_payload_sha256"))

      Reviews.dismiss_orphan_reviews("system:answer-revision", "installation")
      :ok
    else
      {:error, :memory_review_transaction_required}
    end
  end

  def revoke_answer_source_in_transaction(_entry), do: :ok

  defp save_answer(record, response, entry, intent, value) do
    confirmation_ref = "answer:#{response.id}"

    case Repo.one(MemoryEntry.Query.by_confirmation_ref(confirmation_ref)) do
      nil ->
        insert_answer(record, response, entry, intent, value, confirmation_ref)

      %MemoryEntry{status: :active, payload: %{"value" => ^value}} = memory ->
        %{memory: memory, status: :duplicate}

      _ ->
        Repo.rollback(:answer_memory_conflict)
    end
  end

  defp insert_answer(record, response, entry, intent, value, confirmation_ref) do
    id = Ecto.UUID.generate()
    now = Repo.now!()
    payload = %{"value" => value, "applicability" => intent["applicability"]}

    prepared = %{
      expires_at: nil,
      kind: :entity_relationship,
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      scope_kind: :global,
      scope_ref: "installation:#{CanonicalJSON.digest(intent["applicability"])}",
      subject: intent["subject"],
      visibility: :global,
      workspace_ref: "installation"
    }

    attributes =
      Map.merge(prepared, %{
        id: id,
        ref: "memory:#{id}",
        status: :active,
        confirmed_at: response.occurred_at,
        confirmed_by_actor_ref: "#{entry.source_kind}:user:#{response.actor_ref}",
        confirmation_ref: confirmation_ref,
        source_transport: entry.destination_transport,
        source_conversation_ref: entry.destination_conversation_ref,
        source_thread_ref: entry.destination_thread_ref,
        source_message_ref: entry.source_item_ref || entry.event_ref,
        answer_provenance: %{
          "question_ref" => record.ref,
          "question_sha256" => record.payload_fingerprint,
          "answer_ref" => response.response_ref,
          "input_ref" => Inbox.ref(entry),
          "source_revision" => entry.revision,
          "answer_sha256" => entry.event_fingerprint
        }
      })

    with :ok <- answer_not_obsolete(prepared, response.occurred_at),
         :ok <- capacity(prepared),
         :ok <- supersede_existing(prepared),
         changeset =
           attributes
           |> MemoryEntry.Changeset.insert()
           |> Ecto.Changeset.change(inserted_at: now, updated_at: now),
         {:ok, memory} <- Repo.insert(changeset) do
      broadcast_memory_updated(memory.id)
      %{memory: memory, status: :confirmed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp answer_not_obsolete(prepared, answered_at) do
    newer =
      prepared
      |> MemoryEntry.Query.same_subject()
      |> MemoryEntry.Query.changed_after(answered_at)
      |> Repo.exists?()

    if newer, do: {:error, :answer_memory_conflict}, else: :ok
  end

  @spec forget(String.t()) :: {:ok, MemoryEntry.t()} | {:error, term()}
  def forget(ref) do
    with :ok <- reference(ref, :memory_ref) do
      Repo.transaction(fn ->
        Reviews.lock_review_maintenance!()
        entry = forget_locked(ref, nil)
        Reviews.dismiss_orphan_reviews("system:memory-forget")
        entry
      end)
    end
  end

  @spec forget(String.t(), String.t()) :: {:ok, MemoryEntry.t()} | {:error, term()}
  def forget(ref, workspace_ref) do
    with :ok <- reference(ref, :memory_ref),
         :ok <- reference(workspace_ref, :workspace_ref) do
      Repo.transaction(fn ->
        Reviews.lock_review_maintenance!()
        entry = forget_locked(ref, workspace_ref)
        Reviews.dismiss_orphan_reviews("system:memory-forget", workspace_ref)
        entry
      end)
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
        Reviews.lock_review_maintenance!()
        forget_home_locked(ref, actor_ref, workspace_ref)
      end)
    end
  end

  @doc """
  Forgets a fact from a control in the conversation `conversation_ref`: one
  App Home could forget, or one kept to that conversation. Channel controls
  ran through the App Home gate alone, which refuses a channel's own facts
  (2026-10-04 review).
  """
  def forget_in_conversation(ref, actor_ref, workspace_ref, conversation_ref) do
    with :ok <- reference(ref, :memory_ref),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- reference(conversation_ref, :conversation_ref) do
      Repo.transaction(fn ->
        Reviews.lock_review_maintenance!()
        forget_home_locked(ref, actor_ref, workspace_ref, conversation_ref)
      end)
    end
  end

  defp lock_memory(ref),
    do: ref |> MemoryEntry.Query.by_ref() |> MemoryEntry.Query.lock_for_update() |> Repo.one()

  defp forget_home_locked(ref, actor_ref, workspace_ref, conversation_ref \\ nil) do
    case lock_memory(ref) do
      nil ->
        Repo.rollback(:memory_not_found)

      %MemoryEntry{workspace_ref: actual} when actual != workspace_ref ->
        Repo.rollback(:memory_workspace_mismatch)

      %MemoryEntry{} = entry ->
        forget_home_visible(entry, actor_ref, workspace_ref, conversation_ref)
    end
  end

  defp forget_home_visible(entry, actor_ref, workspace_ref, conversation_ref) do
    if Reviews.home_source_visible?(Reviews.review_source_record(:memory, entry), actor_ref) or
         (entry.scope_kind == :conversation and entry.scope_ref == conversation_ref) do
      forgotten = forget_locked(entry.ref, workspace_ref)
      Reviews.dismiss_orphan_reviews("system:memory-forget", workspace_ref)
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

  # The memories context API for callers outside the state layer. Each
  # function is owned by the module it delegates to; see the moduledoc.

  @doc "Returns and accounts for memory visible to one episode's model context."
  defdelegate model_context(episode, repository), to: Recall

  @doc "Returns an actor-filtered App Home page and its exact pending total."
  defdelegate home_reviews(workspace_ref, actor_ref, options \\ []), to: Reviews

  @doc "Returns the oldest pending reviews across every workspace."
  defdelegate pending_reviews(limit \\ 20), to: Reviews
  defdelegate pending_review_count(), to: Reviews
  defdelegate pending_review(review_ref), to: Reviews

  @doc "Fetches one pending review only when every entry is safe for this App Home actor."
  defdelegate fetch_home_review(review_ref, workspace_ref, actor_ref), to: Reviews

  @doc "Resolves one review with a keep, merge, edit or forget decision."
  defdelegate resolve_review(review_ref, action, actor_ref, workspace_ref, replacement \\ nil),
    to: Reviews

  @doc "Resolves a review only when every affected entry is safe in the actor's App Home."
  defdelegate resolve_home_review(
                review_ref,
                action,
                actor_ref,
                workspace_ref,
                replacement \\ nil
              ),
              to: Reviews

  @doc false
  defdelegate delete_slack_channel_in_transaction(workspace_ref, channel_ref), to: Reviews

  @doc """
  Holds the memory review lock until the transaction ends. Every memory write
  takes it before a channel's lock, recording a message's edit or deletion
  among them; deleting a channel, which erases what memory kept of it
  (`delete_slack_channel_in_transaction/2`), takes it before the channel's
  lock too.
  """
  @spec lock_reviews_in_transaction() :: :ok
  defdelegate lock_reviews_in_transaction, to: Reviews, as: :lock_review_maintenance!

  defp confirm_locked(attributes) do
    with {:ok, record, episode, turn} <- lock_offer(attributes.record_ref),
         :ok <-
           ChannelFence.authorize_in_transaction(
             episode.destination_transport,
             episode.destination_conversation_ref
           ),
         :ok <- authorize_wide_offer(record, episode),
         :ok <- delivered_from?(episode, turn, attributes.target) do
      case Repo.one(MemoryEntry.Query.by_offer_record_id(record.id)) do
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

  defp create_memory(record, episode, attributes) do
    prepared = prepare(record.payload, episode, attributes)

    with :ok <- capacity(prepared),
         :ok <- supersede_existing(prepared),
         {:ok, entry} <- insert_entry(record, episode, attributes, prepared),
         {:ok, _confirmed} <- Records.confirm_offer(record, attributes) do
      %{memory: entry, status: :confirmed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare(payload, episode, attributes) do
    workspace = Scope.workspace_ref(episode)
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
    now = Repo.now!()

    existing? = existing_memory?(prepared)
    total = active_memory_count(prepared.workspace_ref, now)
    scoped = scoped_memory_count(prepared, now)

    if existing? or (total < @maximum_total and scoped < @maximum_per_scope),
      do: :ok,
      else: {:error, :memory_capacity_reached}
  end

  defp existing_memory?(prepared) do
    prepared
    |> MemoryEntry.Query.same_subject()
    |> MemoryEntry.Query.active()
    |> Repo.exists?()
  end

  defp active_memory_count(workspace_ref, now) do
    workspace_ref
    |> MemoryEntry.Query.by_workspace()
    |> MemoryEntry.Query.active()
    |> MemoryEntry.Query.unexpired_at(now)
    |> Repo.aggregate(:count)
  end

  defp scoped_memory_count(prepared, now) do
    prepared.workspace_ref
    |> MemoryEntry.Query.by_workspace()
    |> MemoryEntry.Query.scoped_to(prepared.scope_kind, prepared.scope_ref)
    |> MemoryEntry.Query.active()
    |> MemoryEntry.Query.unexpired_at(now)
    |> Repo.aggregate(:count)
  end

  defp list_options(workspace_ref, options) do
    if Keyword.keyword?(options) do
      status = Keyword.get(options, :status)

      if Reference.valid?(workspace_ref) and
           (is_nil(status) or status in [:active, :superseded, :deleted, :expired]) and
           Keyword.keys(options) -- [:status] == [],
         do: {:ok, status},
         else: :error
    else
      :error
    end
  end

  defp list_entries(workspace_ref, status) do
    query = MemoryEntry.Query.by_workspace(workspace_ref)
    query = if status, do: MemoryEntry.Query.with_status(query, status), else: query

    query
    |> MemoryEntry.Query.recently_updated_first()
    |> MemoryEntry.Query.limit_to(1_000)
    |> Repo.all()
  end

  # Callers hold the review maintenance lock: a superseded entry leaves any
  # pending review that named it with nothing to decide, and App Home would go
  # on counting and listing that review until some other maintenance dismissed
  # it, while keeping it failed as stale.
  defp supersede_existing(prepared) do
    superseded =
      prepared
      |> MemoryEntry.Query.same_subject()
      |> MemoryEntry.Query.active()
      |> MemoryEntry.Query.lock_for_update()
      |> Repo.all()

    Enum.each(superseded, &redact!(&1, :superseded, "replaced_payload_sha256"))

    if superseded != [],
      do: Reviews.dismiss_orphan_reviews("system:memory-supersede", prepared.workspace_ref)

    :ok
  end

  defp insert_entry(record, episode, attributes, prepared) do
    id = Ecto.UUID.generate()
    now = Repo.now!()

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
      source_thread_ref: attributes.target.thread_ref,
      source_transport: episode.destination_transport,
      status: :active
    })
    |> MemoryEntry.Changeset.insert()
    |> Ecto.Changeset.change(inserted_at: now, updated_at: now)
    |> Repo.insert()
    |> case do
      {:ok, entry} ->
        broadcast_memory_updated(entry.id)
        {:ok, entry}

      {:error, changeset} ->
        {:error, {:memory_persistence_failed, changeset.errors}}
    end
  end

  defp forget_locked(ref, workspace_ref) do
    case lock_memory(ref) do
      nil ->
        Repo.rollback(:memory_not_found)

      %MemoryEntry{workspace_ref: actual}
      when not is_nil(workspace_ref) and actual != workspace_ref ->
        Repo.rollback(:memory_workspace_mismatch)

      %MemoryEntry{status: :deleted} = entry ->
        entry

      %MemoryEntry{status: status} when status in [:expired, :superseded] ->
        Repo.rollback(:memory_terminal)

      # What learning took from the message the fact came from goes with it:
      # Learned kept the same knowledge after the fact was forgotten (QA
      # re-test, 2026-09-26).
      %MemoryEntry{} = entry ->
        forgotten = redact!(entry, :deleted, "forgotten_payload_sha256")
        _learning = Forgetting.forget_fact_in_transaction(entry)
        forgotten
    end
  end

  defp lock_offer(record_ref) do
    case Records.lock_offer(record_ref, ["memory_offer"]) do
      {:error, :not_found} -> {:error, :memory_offer_not_found}
      found -> found
    end
  end

  defp delivered_from?(episode, turn, target) do
    case CardDelivery.delivered_from?(episode, turn, target) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :memory_offer_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :memory_offer_not_delivered}
    end
  end

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

  defp utc_datetime(value) do
    case UTCDateTime.exact(value) do
      {:ok, exact} -> {:ok, exact}
      :error -> {:error, {:invalid_memory_confirmation, :occurred_at}}
    end
  end

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  # Value rules shared with Memories.Recall and Memories.Reviews. They live
  # here once; the error tuples are the memories confirmation vocabulary.

  @doc false
  def reference(value, field) do
    if Reference.valid?(value), do: :ok, else: {:error, {:invalid_memory_confirmation, field}}
  end

  @doc false
  def datetime(nil), do: nil
  def datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)

  @doc false
  def redact!(entry, status, hash_field) do
    payload = %{hash_field => entry.payload_fingerprint}
    fingerprint = CanonicalJSON.digest(payload)

    entry
    |> MemoryEntry.Changeset.redact(status, payload, fingerprint)
    |> Repo.update!()
    |> tap(&broadcast_memory_updated(&1.id))
  end

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to memory changes: `{:memory_updated, id}` once a
  fact, a review item or a remembered case changes, and that change has
  committed. `id` is the changed row's.
  """
  def subscribe_memories, do: Ryker.PubSub.subscribe(memories_topic())

  def unsubscribe_memories, do: Ryker.PubSub.unsubscribe(memories_topic())

  @doc """
  Internal — announces, after the outermost commit, that the fact, review
  item or remembered case `id` changed. The memory modules that write one call
  this.
  """
  @spec broadcast_memory_updated(Ecto.UUID.t()) :: :ok
  def broadcast_memory_updated(id) when is_binary(id) do
    Repo.after_commit(fn -> Ryker.PubSub.broadcast(memories_topic(), {:memory_updated, id}) end)
  end

  defp memories_topic, do: "memories"
end
