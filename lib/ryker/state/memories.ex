defmodule Ryker.State.Memories do
  @moduledoc """
  Operator-confirmed operational memory with exact scope and provenance.

  Memory is a potentially stale model hint. It cannot start work, satisfy an
  evidence requirement, choose a repository policy, or authorize an effect.
  Replacement and forgetting erase the stored value while retaining only its
  digest and lifecycle identity.

  This module owns the entry lifecycle: confirming an offer or a reusable
  answer, forgetting, revoking on source edits, and listing. Reading memory
  for a model context lives in `Ryker.State.Memories.Recall`; the stale and
  duplicate review queue lives in `Ryker.State.Memories.Reviews`. The
  delegates below are the memories context API for callers outside the state
  layer (Slack, the control plane, work submission), not a compatibility shim:
  callers inside the state, retention, and tooling layers call the owning
  module directly.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Slack.ChannelFence

  alias Ryker.State.{
    CardDelivery,
    MemoryEntry,
    MemoryEntryChangeset,
    Record,
    RecordChangeset,
    Response,
    Scope
  }

  alias Ryker.State.Memories.{Recall, Reviews}
  alias Ryker.StateTools.Binding
  alias Ryker.UTCDateTime
  alias Ryker.Work.Turn

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
    if String.valid?(value) and String.trim(value) != "" and byte_size(value) <= 4_000 and
         not String.contains?(value, <<0>>) do
      Repo.transaction(fn -> confirm_answer_locked(binding, record_ref, value, authorize) end)
    else
      {:error, :invalid_answer_memory}
    end
  end

  def confirm_answer(_binding, _record_ref, _value, _authorize),
    do: {:error, :answer_memory_unauthorized}

  defp confirm_answer_locked(binding, record_ref, value, authorize) do
    with {:ok, current} <- Binding.lock_current(binding),
         :live <- current.episode.execution_mode,
         :ok <- Reviews.lock_review_maintenance!(),
         {record, response, entry} <- answer_confirmation(current, record_ref),
         true <- authorize.(entry) == true,
         %{} = intent <- record.payload["remember"],
         false <- answer_revised?(entry) do
      save_answer(record, response, entry, intent, value)
    else
      _ -> Repo.rollback(:answer_memory_unauthorized)
    end
  end

  defp answer_confirmation(binding, record_ref) do
    Repo.one(
      from(record in Record,
        join: response in Response,
        on: response.record_id == record.id,
        join: entry in Entry,
        on: entry.id == response.inbox_entry_id,
        where:
          record.ref == ^record_ref and record.kind == "input_request" and
            record.status == :answered and record.episode_id == ^binding.episode.id and
            entry.episode_id == ^binding.episode.id and entry.status == :decided and
            entry.actor_kind == :user and entry.execution_mode == :live and
            is_nil(entry.operational_pruned_at),
        select: {record, response, entry},
        lock: "FOR UPDATE"
      )
    )
  end

  defp answer_revised?(entry) do
    Repo.exists?(
      from(newer in Entry,
        where:
          newer.source_kind == ^entry.source_kind and newer.source_ref == ^entry.source_ref and
            newer.native_input_id == ^entry.native_input_id and newer.revision > ^entry.revision
      )
    )
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

      Repo.all(
        from(memory in MemoryEntry,
          where:
            memory.scope_kind == :global and memory.status == :active and
              memory.source_transport == ^entry.destination_transport and
              memory.source_conversation_ref == ^entry.destination_conversation_ref and
              memory.source_message_ref == ^source_ref and
              fragment("(?::jsonb->>'source_revision')::bigint", memory.answer_provenance) <
                ^entry.revision,
          lock: "FOR UPDATE"
        )
      )
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

    case Repo.get_by(MemoryEntry, confirmation_ref: confirmation_ref) do
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
         {:ok, memory} <-
           attributes
           |> MemoryEntryChangeset.insert()
           |> Ecto.Changeset.change(inserted_at: now, updated_at: now)
           |> Repo.insert() do
      %{memory: memory, status: :confirmed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp answer_not_obsolete(prepared, answered_at) do
    newer =
      Repo.exists?(
        from(memory in MemoryEntry,
          where:
            memory.workspace_ref == ^prepared.workspace_ref and
              memory.scope_kind == ^prepared.scope_kind and
              memory.scope_ref == ^prepared.scope_ref and memory.kind == ^prepared.kind and
              memory.subject == ^prepared.subject and
              fragment(
                "GREATEST(?, ?, CASE WHEN ? = 'deleted' THEN ? END) > ?",
                memory.confirmed_at,
                memory.edited_at,
                memory.status,
                memory.updated_at,
                type(^answered_at, :utc_datetime_usec)
              )
        )
      )

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

  defp forget_home_locked(ref, actor_ref, workspace_ref) do
    case Repo.one(from(entry in MemoryEntry, where: entry.ref == ^ref, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:memory_not_found)

      %MemoryEntry{workspace_ref: actual} when actual != workspace_ref ->
        Repo.rollback(:memory_workspace_mismatch)

      %MemoryEntry{} = entry ->
        forget_home_visible(entry, actor_ref, workspace_ref)
    end
  end

  defp forget_home_visible(entry, actor_ref, workspace_ref) do
    if Reviews.home_source_visible?(Reviews.review_source_record(:memory, entry), actor_ref) do
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

  @doc "Fetches one pending review only when every entry is safe for this App Home actor."
  defdelegate fetch_home_review(review_ref, workspace_ref, actor_ref), to: Reviews

  @doc "Resolves one review with a keep, merge, edit, forget, or dismiss decision."
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
            (is_nil(entry.expires_at) or entry.expires_at > ^now)
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
            entry.status == :active and (is_nil(entry.expires_at) or entry.expires_at > ^now)
      ),
      :count
    )
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
    query =
      from(entry in MemoryEntry,
        where: entry.workspace_ref == ^workspace_ref,
        order_by: [desc: entry.updated_at, desc: entry.id],
        limit: 1_000
      )

    query = if status, do: from(entry in query, where: entry.status == ^status), else: query
    Repo.all(query)
  end

  # Callers hold the review maintenance lock: a superseded entry leaves any
  # pending review that named it with nothing to decide, and App Home would go
  # on counting and listing that review until some other maintenance dismissed
  # it, while keeping it failed as stale.
  defp supersede_existing(prepared) do
    superseded =
      Repo.all(
        from(entry in MemoryEntry,
          where:
            entry.workspace_ref == ^prepared.workspace_ref and
              entry.scope_kind == ^prepared.scope_kind and
              entry.scope_ref == ^prepared.scope_ref and
              entry.kind == ^prepared.kind and entry.subject == ^prepared.subject and
              entry.status == :active,
          lock: "FOR UPDATE"
        )
      )

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
    |> MemoryEntryChangeset.insert()
    |> Ecto.Changeset.change(inserted_at: now, updated_at: now)
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
    |> MemoryEntryChangeset.redact(status, payload, fingerprint)
    |> Repo.update!()
  end
end
