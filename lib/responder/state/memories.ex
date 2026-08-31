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

  alias Responder.State.{MemoryEntry, MemoryEntryChangeset, Record, RecordChangeset}
  alias Responder.Work.Turn

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
        confirm_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
      |> transaction_result()
    end
  end

  @spec forget(String.t()) :: {:ok, MemoryEntry.t()} | {:error, term()}
  def forget(ref) do
    with :ok <- reference(ref, :memory_ref) do
      Repo.transaction(fn -> forget_locked(ref, nil) end)
      |> transaction_result()
    end
  end

  @spec forget(String.t(), String.t()) :: {:ok, MemoryEntry.t()} | {:error, term()}
  def forget(ref, workspace_ref) do
    with :ok <- reference(ref, :memory_ref),
         :ok <- reference(workspace_ref, :workspace_ref) do
      Repo.transaction(fn -> forget_locked(ref, workspace_ref) end)
      |> transaction_result()
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

  defp confirm_locked(attributes) do
    with {:ok, record, episode, turn} <- lock_offer(attributes.record_ref),
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
    now = database_now!()

    entries =
      Repo.all(
        from(entry in MemoryEntry,
          where:
            entry.workspace_ref == ^context.workspace_ref and entry.status == :active and
              entry.expires_at > ^now,
          order_by: [desc: entry.updated_at, desc: entry.id],
          limit: 1_000
        )
      )
      |> Enum.filter(&visible?(&1, context))
      |> Enum.sort_by(&rank/1)
      |> Enum.take(limit)

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
