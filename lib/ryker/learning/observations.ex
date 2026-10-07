defmodule Ryker.Learning.Observations do
  @moduledoc "Authenticated source custody and bounded original excerpts, never model-written memories."
  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.Continuity
  alias Ryker.Continuity.Relevance
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.RecallText
  alias Ryker.Knowledge
  alias Ryker.Learning
  alias Ryker.Learning.ConversationObservation
  alias Ryker.Learning.{LearningSources, Visibility}
  alias Ryker.Memories.MemorySearchPage
  alias Ryker.Memories.MemorySourceLink
  alias Ryker.Memories.SearchPage
  alias Ryker.Publication.{LifecycleEvent, Publication}
  alias Ryker.Slack.{ChannelFence, ChannelMembership}

  @doc "Retain a deterministic excerpt of the original input with only that source's receipt."
  def record_excerpt_in_transaction(%Entry{status: :decided} = entry),
    do: write_source(entry, excerpt(entry), "input:#{entry.id}", :source_only)

  def record_excerpt_in_transaction(_), do: {:error, :observation_source_not_decided}

  # What the message said, as routing reads it among the others. The original
  # values an anchor is checked against include ids and types no one wrote.
  defp excerpt(entry) do
    text = entry.content |> RecallText.prose() |> String.trim()

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
           Repo.one(Publication.Query.by_id(publication_id)),
         %LifecycleEvent{
           kind: :review_feedback,
           publication_id: ^publication_id,
           episode_id: ^episode_id,
           observation:
             %{
               "source" => %{"kind" => "github", "ref" => source_ref},
               "native_input_id" => native,
               "revision" => revision,
               "actor" => %{"kind" => actor_kind, "ref" => actor_ref}
             } = document
         } = event <- Repo.one(LifecycleEvent.Query.by_id(id)),
         %Episode{} = episode <- Repo.one(Episode.Query.by_id(episode_id)) do
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
         :ok <-
           ChannelFence.authorize_in_transaction(
             entry.destination_transport,
             entry.destination_conversation_ref
           ),
         {:ok, scope} <- Continuity.destination_context(entry, entry.repository_ref) do
      now = Keyword.get_lazy(options, :received_at, &Repo.now!/0)
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
             on_conflict: ConversationObservation.Query.monotonic_update(updates),
             conflict_target: [:identity_key],
             allow_stale: true
           ) do
        {:ok, _} ->
          Learning.broadcast_learning_updated(entry.id)
          quarantine_conflicting_revision(entry)

        {:error, reason} ->
          {:error, reason}
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
      identity
      |> ConversationObservation.Query.by_identity()
      |> ConversationObservation.Query.lock_for_update()
      |> Repo.one!()

    if current.revision == entry.revision and current.source_input_id != entry.id and
         not source_conflicted?(current) and
         retained_content(current) != normalized_content(entry.content, entry.source_kind) do
      fingerprint =
        CanonicalJSON.digest(%{
          "source" => identity,
          "revision" => entry.revision,
          "state" => "conflict"
        })

      Repo.update_all(ConversationObservation.Query.by_id(current.id),
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
    case Repo.one(LifecycleEvent.Query.by_id(id)) do
      %LifecycleEvent{kind: :review_feedback, observation: %{"content" => content}} ->
        normalized_content(content, "github")

      _ ->
        :missing
    end
  end

  defp retained_content(source) do
    case Repo.one(Entry.Query.by_id(source.source_input_id)) do
      %Entry{content: content, source_kind: kind} -> normalized_content(content, kind)
      _ -> :missing
    end
  end

  defp normalized_content(content, "github") when is_map(content),
    do: Map.delete(content, "delivery_ref")

  defp normalized_content(content, _) when is_map(content), do: content
  defp normalized_content(_, _), do: :missing

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

  # Notes ranked for a request are chosen from this many of the conversation's, in the order
  # `context/5` reads them.
  @related_candidates 32
  @related_limit 16

  @doc """
  The notes a model receives beside `input_texts`: those `context/5` would give, chosen from
  more of them, the ones sharing most with the request first (`Ryker.Continuity.Relevance`).
  """
  @spec related_context(term(), String.t() | nil, [String.t()]) :: [map()]
  def related_context(destination, repository_ref, input_texts) do
    request = Relevance.request(input_texts)

    destination
    |> context(repository_ref, "", @related_candidates)
    |> Relevance.rank(request, &note_text/1)
    |> Enum.take(@related_limit)
  end

  defp note_text(note), do: Enum.join([note["summary"] | List.wrap(note["topics"])], "\n")

  @doc "Recheck the exact frozen notes before a model submission or accepting its decision."
  def reauthorize(_destination, _repository_ref, []), do: :ok

  def reauthorize(destination, repository_ref, documents) when is_list(documents) do
    case Repo.transaction(fn -> reauthorize_locked(destination, repository_ref, documents) end) do
      {:ok, true} -> :ok
      _ -> {:error, {:admission_rejected, :context_stale}}
    end
  rescue
    error in Postgrex.Error ->
      if Repo.conflict?(error),
        do: {:error, {:admission_rejected, :context_stale}},
        else: reraise(error, __STACKTRACE__)
  end

  defp reauthorize_locked(destination, repository_ref, documents) do
    ids = Enum.map(documents, &observation_id/1)

    with true <- Enum.all?(ids, &is_binary/1),
         {:ok, scope} <- locked_scope(destination, repository_ref) do
      notes =
        ids
        |> ConversationObservation.Query.by_ids()
        |> ConversationObservation.Query.in_workspace(scope.workspace_ref)
        |> ConversationObservation.Query.having_note()
        |> Visibility.Query.visible_from(scope)
        |> ConversationObservation.Query.lock_for_share()
        |> Repo.all()

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
    scope.workspace_ref
    |> ConversationObservation.Query.in_workspace()
    |> ConversationObservation.Query.having_note()
    |> ConversationObservation.Query.not_among(Knowledge.current_source_ids_query(scope))
    |> Visibility.Query.visible_from(scope)
    |> ConversationObservation.Query.ordered_by_recall_precedence(scope)
    |> ConversationObservation.Query.limit_to(limit)
    |> LearningSources.eligible(scope)
    |> ConversationObservation.Query.within_scope(scope, search_scope)
    |> ConversationObservation.Query.matching(search)
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
    fields = ConversationObservation.Query.search_fields()

    # Explicit history search includes originals even after their topic was
    # consolidated. Otherwise an older source date becomes unreachable.
    scope.workspace_ref
    |> ConversationObservation.Query.in_workspace()
    |> ConversationObservation.Query.having_note()
    |> Visibility.Query.visible_from(scope)
    |> ConversationObservation.Query.lock_for_share()
    |> LearningSources.eligible(scope)
    |> ConversationObservation.Query.within_scope(scope, page.scope)
    |> SearchPage.Query.related_sources(page)
    |> MemorySearchPage.one(page, fields.text, fields.changed, fields.source)
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
    refs
    |> ChannelMembership.Query.by_conversation_refs()
    |> ChannelMembership.Query.lock_for_share()
    |> Repo.all()
    |> Map.new()
  end

  @doc false
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
end
