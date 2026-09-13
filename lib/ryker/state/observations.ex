defmodule Ryker.State.Observations do
  @moduledoc "Authenticated source custody and bounded original excerpts, never model-written memories."
  import Ecto.Query
  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Publication.{LifecycleEvent, Publication}
  alias Ryker.Slack.{ChannelFence, ChannelMembership}

  alias Ryker.State.{
    Continuity,
    ConversationObservation,
    Knowledge,
    KnowledgeAnchors,
    LearningSources,
    MemorySearchPage,
    MemorySourceLink
  }

  defp prepare(nil), do: {:ok, nil}

  defp prepare(%{"summary" => summary, "topics" => topics} = note) when map_size(note) == 2 do
    if text?(summary, 1_200) and is_list(topics) and length(topics) <= 8 and
         Enum.all?(topics, &text?(&1, 80)) and length(topics) == length(Enum.uniq(topics)),
       do: {:ok, note},
       else: {:error, {:invalid_decision, :observation}}
  end

  defp prepare(_), do: {:error, {:invalid_decision, :observation}}

  @doc "Retain a deterministic excerpt of the original input with only that source's receipt."
  def record_excerpt_in_transaction(%Entry{status: :decided} = entry),
    do: write_source(entry, excerpt(entry), "input:#{entry.id}", :source_only)

  def record_excerpt_in_transaction(_), do: {:error, :observation_source_not_decided}

  defp excerpt(entry) do
    text =
      entry
      |> List.wrap()
      |> KnowledgeAnchors.source_texts()
      |> Enum.join("\n")
      |> String.trim()

    if text != "" do
      summary = if String.length(text) > 1200, do: String.slice(text, 0, 1199) <> "…", else: text
      %{"summary" => summary, "topics" => []}
    end
  end

  @doc "Revoke previous facts immediately when authenticated source custody advances."
  def receive_in_transaction(%Entry{} = entry), do: write_source(entry, nil, nil, nil)

  @doc "Retain matched review feedback's immutable custody without creating an Admission input."
  def record_publication_feedback_in_transaction(
        %LifecycleEvent{id: id},
        %Publication{id: publication_id, episode_id: episode_id, repository: repository}
      ) do
    with true <- Repo.in_transaction?(),
         %Publication{episode_id: ^episode_id, repository: ^repository} <-
           Repo.get(Publication, publication_id),
         %LifecycleEvent{
           kind: "review_feedback",
           publication_id: ^publication_id,
           episode_id: ^episode_id,
           observation:
             %{
               "source" => %{"kind" => "github", "ref" => source_ref},
               "native_input_id" => native,
               "revision" => revision,
               "actor" => %{"kind" => actor_kind, "ref" => actor_ref}
             } = document
         } = event <- Repo.get(LifecycleEvent, id),
         %Episode{} = episode <- Repo.get(Episode, episode_id) do
      source = %{
        id: event.id,
        source_kind: "github",
        source_ref: source_ref,
        native_input_id: native,
        revision: revision,
        event_kind: if(document["event_kind"] == "delete", do: :delete, else: :event),
        event_fingerprint: CanonicalJSON.digest(document),
        content: document["content"],
        source_item_ref: document["source_item_ref"],
        actor_ref: "github:#{actor_kind}:#{actor_ref}",
        occurred_at: event.occurred_at,
        episode_id: episode.id,
        execution_mode: episode.execution_mode,
        destination_transport: episode.destination_transport,
        destination_conversation_ref: episode.destination_conversation_ref,
        destination_thread_ref: episode.destination_thread_ref,
        repository_ref: repository
      }

      # The PR may be private even when the engineering task lives in a public
      # Slack channel. Routing grants this conversation, not workspace-wide recall.
      write_source(source, nil, "publication-feedback:#{event.id}", :source_only,
        visibility: :private,
        received_at: event.inserted_at
      )
    else
      _ -> {:error, :publication_feedback_source_invalid}
    end
  end

  @doc false
  def source_identity(entry) do
    CanonicalJSON.digest(%{
      "source_kind" => entry.source_kind,
      "source_ref" => entry.source_ref,
      "native_input_id" => entry.native_input_id
    })
  end

  defp write_source(entry, note, result_ref, sources, options \\ []) do
    with true <- Repo.in_transaction?(),
         {:ok, note} <- prepare(note),
         :ok <-
           ChannelFence.authorize_in_transaction(
             entry.destination_transport,
             entry.destination_conversation_ref
           ),
         {:ok, scope} <- Continuity.destination_context(entry, entry.repository_ref) do
      now = Keyword.get_lazy(options, :received_at, &database_now!/0)
      scope = Map.put(scope, :visibility, Keyword.get(options, :visibility, scope.visibility))

      # Keep a revision tombstone even when an edit has nothing to remember. A
      # slower classifier for the previous revision must never resurrect it.
      record =
        struct!(
          ConversationObservation,
          Map.merge(scope, %{
            id: entry.id,
            identity_key: source_identity(entry),
            source_input_id: entry.id,
            source_episode_id: entry.episode_id,
            source_message_ref: entry.source_item_ref || entry.native_input_id,
            source_result_ref: result_ref,
            source_fingerprint: entry.event_fingerprint,
            actor_ref: entry.actor_ref,
            execution_mode: entry.execution_mode,
            revision: entry.revision,
            occurred_at: entry.occurred_at,
            note: if(entry.event_kind == :delete, do: nil, else: note),
            inserted_at: now,
            updated_at: now
          })
        )

      sources = if sources == :source_only, do: LearningSources.for_source(record), else: sources

      record = %{
        record
        | source_dependencies: sources,
          note: if(is_list(sources), do: record.note)
      }

      fields =
        ~w(transport workspace_ref conversation_ref repository_ref thread_ref visibility source_input_id source_episode_id source_message_ref source_result_ref source_fingerprint actor_ref execution_mode revision occurred_at note source_dependencies updated_at)a

      updates = Enum.map(fields, &{&1, Map.fetch!(record, &1)})

      case Repo.insert(record,
             on_conflict: monotonic_source_update(updates),
             conflict_target: [:identity_key],
             allow_stale: true
           ) do
        {:ok, _} -> quarantine_conflicting_revision(entry)
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :observation_transaction_required}
      {:error, :slack_channel_deleted} -> :ok
      {:error, _} = error -> error
    end
  end

  defp quarantine_conflicting_revision(entry) do
    identity = source_identity(entry)

    # Check after the upsert, while holding the row lock. Even two concurrent
    # first deliveries must not leave either text authoritative after a tie.
    current =
      Repo.one!(
        from(o in ConversationObservation, where: o.identity_key == ^identity, lock: "FOR UPDATE")
      )

    if current.revision == entry.revision and current.source_input_id != entry.id and
         not source_conflicted?(current) and
         retained_content(current) != normalized_content(entry.content, entry.source_kind) do
      fingerprint =
        CanonicalJSON.digest(%{
          "source" => identity,
          "revision" => entry.revision,
          "state" => "conflict"
        })

      Repo.update_all(from(o in ConversationObservation, where: o.id == ^current.id),
        set: [
          source_result_ref: "source-conflict:#{identity}:#{entry.revision}",
          source_fingerprint: fingerprint,
          source_dependencies: nil,
          note: nil
        ]
      )
    end

    :ok
  end

  defp source_conflicted?(%{source_result_ref: "source-conflict:" <> _}), do: true
  defp source_conflicted?(_), do: false

  defp retained_content(%{source_input_id: id, source_result_ref: "publication-feedback:" <> id}) do
    case Repo.get(LifecycleEvent, id) do
      %LifecycleEvent{kind: "review_feedback", observation: %{"content" => content}} ->
        normalized_content(content, "github")

      _ ->
        :missing
    end
  end

  defp retained_content(source) do
    case Repo.get(Entry, source.source_input_id) do
      %Entry{content: content, source_kind: kind} -> normalized_content(content, kind)
      _ -> :missing
    end
  end

  defp normalized_content(content, "github") when is_map(content),
    do: Map.delete(content, "delivery_ref")

  defp normalized_content(content, _) when is_map(content), do: content
  defp normalized_content(_, _), do: :missing

  defp monotonic_source_update(updates) do
    updates = Keyword.delete(updates, :updated_at)

    from(old in ConversationObservation,
      where:
        old.revision < fragment("EXCLUDED.revision") or
          (old.revision == fragment("EXCLUDED.revision") and
             old.source_input_id == fragment("EXCLUDED.source_input_id") and
             old.source_fingerprint == fragment("EXCLUDED.source_fingerprint") and
             is_nil(old.source_result_ref) and
             not is_nil(fragment("EXCLUDED.source_result_ref"))),
      update: [set: ^updates],
      update: [
        set: [
          updated_at:
            fragment(
              "CASE WHEN ? = EXCLUDED.revision THEN ? ELSE EXCLUDED.updated_at END",
              old.revision,
              old.updated_at
            )
        ]
      ]
    )
  end

  def context(destination, repository_ref, query \\ "", limit \\ 16, search_scope \\ "workspace") do
    case Repo.transaction(fn ->
           recall_authorized(destination, repository_ref, query, limit, search_scope)
         end) do
      {:ok, notes} -> notes
      _ -> []
    end
  end

  defp recall_authorized(destination, repository_ref, query, limit, search_scope) do
    case locked_scope(destination, repository_ref) do
      {:ok, scope} -> recall(scope, query, min(max(limit, 1), 32), search_scope)
      _ -> []
    end
  end

  @doc "Recheck the exact frozen notes before a model submission or accepting its decision."
  def reauthorize(_destination, _repository_ref, []), do: :ok

  def reauthorize(destination, repository_ref, documents) when is_list(documents) do
    case Repo.transaction(fn -> reauthorize_locked(destination, repository_ref, documents) end) do
      {:ok, true} -> :ok
      _ -> {:error, {:admission_rejected, :context_stale}}
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in [:serialization_failure, :deadlock_detected],
        do: {:error, {:admission_rejected, :context_stale}},
        else: reraise(error, __STACKTRACE__)
  end

  defp reauthorize_locked(destination, repository_ref, documents) do
    ids = Enum.map(documents, &observation_id/1)

    with true <- Enum.all?(ids, &is_binary/1),
         {:ok, scope} <- locked_scope(destination, repository_ref) do
      allowed = visible_conversations(scope)

      notes =
        Repo.all(
          from(note in ConversationObservation,
            where:
              note.id in ^ids and note.workspace_ref == ^scope.workspace_ref and
                not is_nil(note.note),
            where: ^allowed,
            lock: "FOR SHARE"
          )
        )

      current =
        notes
        |> authorized_notes(scope)
        |> Enum.filter(&LearningSources.valid?(&1.source_dependencies, scope))
        |> Enum.map(&document/1)

      MapSet.new(current) == MapSet.new(documents)
    else
      _ -> false
    end
  end

  defp observation_id(%{"source_ref" => "observation:" <> id}) do
    case Ecto.UUID.cast(id) do
      {:ok, ^id} -> id
      _ -> nil
    end
  end

  defp observation_id(_), do: nil

  @doc false
  def locked_scope(destination, repository_ref) do
    with :ok <-
           ChannelFence.authorize_in_transaction(
             destination.destination_transport,
             destination.destination_conversation_ref
           ) do
      # Under REPEATABLE READ, advisory locks alone do not refresh a snapshot.
      # Locking the actual membership row rejects a snapshot predating revocation.
      lock_memberships([destination.destination_conversation_ref])

      with {:ok, scope} <- Continuity.destination_context(destination, repository_ref) do
        {:ok, LearningSources.with_input_boundary(scope, destination)}
      end
    end
  end

  defp recall(scope, search, limit, search_scope) do
    allowed = visible_conversations(scope)

    query =
      from(note in ConversationObservation,
        where: note.workspace_ref == ^scope.workspace_ref and not is_nil(note.note),
        where: note.id not in subquery(Knowledge.current_source_ids_query(scope)),
        where: ^allowed,
        order_by: [
          desc: note.conversation_ref == ^scope.conversation_ref,
          desc: fragment("? IS NOT DISTINCT FROM ?", note.repository_ref, ^scope.repository_ref),
          desc: note.occurred_at,
          desc: note.id
        ],
        limit: ^limit
      )

    query
    |> LearningSources.eligible(scope)
    |> within_scope(scope, search_scope)
    |> matching(search)
    |> Repo.all()
    |> authorized_notes(scope)
    |> Enum.filter(&LearningSources.valid?(&1.source_dependencies, scope))
    |> Enum.map(&document/1)
  end

  @doc false
  def search_page(destination, repository_ref, page) do
    case locked_scope(destination, repository_ref) do
      {:ok, scope} -> search_visible_page(scope, page)
      _ -> :done
    end
  end

  defp search_visible_page(scope, page) do
    query =
      from(note in ConversationObservation,
        where: note.workspace_ref == ^scope.workspace_ref and not is_nil(note.note),
        where: ^visible_conversations(scope),
        lock: "FOR SHARE"
      )
      |> LearningSources.eligible(scope)
      |> within_scope(scope, page.scope)
      |> MemorySearchPage.related_sources(page)

    # Explicit history search includes originals even after their topic was
    # consolidated. Otherwise an older source date becomes unreachable.
    query
    |> MemorySearchPage.one(
      page,
      dynamic([n], n.note),
      dynamic([n], n.updated_at),
      dynamic([n], n.occurred_at)
    )
    |> authorize_search_result(scope)
  end

  defp authorize_search_result({:ok, note, position}, scope) do
    if authorized_notes([note], scope) != [] and
         LearningSources.valid?(note.source_dependencies, scope),
       do: {:ok, document(note), position},
       else: {:skip, position}
  end

  defp authorize_search_result(:done, _scope), do: :done

  @doc false
  def authorized_notes(notes, scope) do
    members = notes |> Enum.map(& &1.conversation_ref) |> lock_memberships()

    Enum.filter(notes, fn note ->
      note.conversation_ref == scope.conversation_ref or
        (scope.visibility == :public and note.visibility == :public and
           Map.get(members, note.conversation_ref) == {:joined, false, false})
    end)
  end

  defp lock_memberships(refs) do
    Repo.all(
      from(member in ChannelMembership,
        where:
          fragment("'slack:' || ? || ':' || ?", member.workspace_ref, member.channel_ref) in ^refs,
        order_by: [asc: member.workspace_ref, asc: member.channel_ref],
        lock: "FOR SHARE",
        select:
          {fragment("'slack:' || ? || ':' || ?", member.workspace_ref, member.channel_ref),
           {member.status, member.private, member.external_shared}}
      )
    )
    |> Map.new()
  end

  @doc false
  def visible_conversations(%{transport: "slack", visibility: :public} = scope) do
    workspace = String.replace_prefix(scope.workspace_ref, "slack:", "")

    public =
      from(member in ChannelMembership,
        where:
          member.workspace_ref == ^workspace and member.status == :joined and
            member.private == false and member.external_shared == false,
        select: fragment("'slack:' || ? || ':' || ?", member.workspace_ref, member.channel_ref)
      )

    dynamic(
      [note],
      note.conversation_ref == ^scope.conversation_ref or
        (note.visibility == :public and note.conversation_ref in subquery(public))
    )
  end

  def visible_conversations(scope),
    do: dynamic([note], note.conversation_ref == ^scope.conversation_ref)

  defp within_scope(query, _scope, "workspace"), do: query

  defp within_scope(query, scope, "current_channel"),
    do: from(note in query, where: note.conversation_ref == ^scope.conversation_ref)

  defp within_scope(query, %{repository_ref: repository}, "repository")
       when is_binary(repository),
       do: from(note in query, where: note.repository_ref == ^repository)

  defp within_scope(query, _scope, _search_scope), do: from(note in query, where: false)

  defp matching(query, search) when is_binary(search) do
    search = String.slice(String.trim(search), 0, 200)
    from(note in query, where: fragment("position(lower(?) in lower(?)) > 0", ^search, note.note))
  end

  defp matching(query, _search), do: query

  def document(note) do
    Map.merge(original_document(note), %{
      "source_read" =>
        MemorySourceLink.message(
          note.transport,
          note.conversation_ref,
          note.source_message_ref,
          note.thread_ref
        ),
      "thread_ref" => note.thread_ref
    })
  end

  @doc false
  def original_document(note) do
    %{
      "kind" => "conversation_observation",
      "source_ref" => "observation:#{note.id}",
      "summary" => note.note["summary"],
      "topics" => note.note["topics"],
      "conversation_ref" => note.conversation_ref,
      "source_message_ref" => note.source_message_ref,
      "source_input_id" => note.source_input_id,
      "actor_ref" => note.actor_ref,
      "occurred_at" => DateTime.to_iso8601(note.occurred_at)
    }
  end

  defp text?(value, maximum),
    do:
      is_binary(value) and String.valid?(value) and
        String.length(value) <= maximum and String.trim(value) != "" and
        not String.contains?(value, <<0>>)

  defp database_now! do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end
end
