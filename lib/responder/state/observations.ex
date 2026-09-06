defmodule Responder.State.Observations do
  @moduledoc "Source-linked conversation notes, independent of the decision to respond."
  import Ecto.Query
  alias Responder.{CanonicalJSON, Repo}
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Slack.{ChannelFence, ChannelMembership}
  alias Responder.State.{Continuity, ConversationObservation}

  def prepare(nil), do: {:ok, nil}

  def prepare(%{"summary" => summary, "topics" => topics} = note) when map_size(note) == 2 do
    if text?(summary, 1_200) and is_list(topics) and length(topics) <= 8 and
         Enum.all?(topics, &text?(&1, 80)) and length(topics) == length(Enum.uniq(topics)),
       do: {:ok, note},
       else: {:error, {:invalid_decision, :observation}}
  end

  def prepare(_), do: {:error, {:invalid_decision, :observation}}

  def json_schema do
    %{
      "anyOf" => [
        %{"type" => "null"},
        %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["summary", "topics"],
          "properties" => %{
            "summary" => text_schema(1_200),
            "topics" => %{
              "type" => "array",
              "maxItems" => 8,
              "uniqueItems" => true,
              "items" => text_schema(80)
            }
          }
        }
      ]
    }
  end

  @doc "Persist only after the source decision wins custody, without creating an episode or effect."
  def record_in_transaction(%Entry{status: :decided} = entry, note, result_ref)
      when is_binary(result_ref) and result_ref != "" do
    with true <- Repo.in_transaction?(),
         {:ok, note} <- prepare(note),
         :ok <-
           ChannelFence.authorize_in_transaction(
             entry.destination_transport,
             entry.destination_conversation_ref
           ),
         {:ok, scope} <- Continuity.destination_context(entry, entry.repository_ref) do
      identity =
        CanonicalJSON.digest(%{
          "source_kind" => entry.source_kind,
          "source_ref" => entry.source_ref,
          "native_input_id" => entry.native_input_id
        })

      now = DateTime.utc_now()

      # Keep a revision tombstone even when an edit has nothing to remember. A
      # slower classifier for the previous revision must never resurrect it.
      record =
        struct!(
          ConversationObservation,
          Map.merge(scope, %{
            id: entry.id,
            identity_key: identity,
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

      fields =
        ~w(visibility source_input_id source_episode_id source_message_ref source_result_ref source_fingerprint actor_ref execution_mode revision occurred_at note updated_at)a

      updates = Enum.map(fields, &{&1, Map.fetch!(record, &1)})

      conflict =
        from(old in ConversationObservation,
          where: old.revision < fragment("EXCLUDED.revision"),
          update: [set: ^updates]
        )

      case Repo.insert(record,
             on_conflict: conflict,
             conflict_target: [:identity_key],
             allow_stale: true
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      false -> {:error, :observation_transaction_required}
      {:error, :slack_channel_deleted} -> :ok
      {:error, _} = error -> error
    end
  end

  def record_in_transaction(_, _, _), do: {:error, :observation_source_not_decided}

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

      current = notes |> authorized_notes(scope) |> Enum.map(&document/1)
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

  defp locked_scope(destination, repository_ref) do
    with :ok <-
           ChannelFence.authorize_in_transaction(
             destination.destination_transport,
             destination.destination_conversation_ref
           ) do
      # Under REPEATABLE READ, advisory locks alone do not refresh a snapshot.
      # Locking the actual membership row rejects a snapshot predating revocation.
      lock_memberships([destination.destination_conversation_ref])
      Continuity.destination_context(destination, repository_ref)
    end
  end

  defp recall(scope, search, limit, search_scope) do
    allowed = visible_conversations(scope)

    query =
      from(note in ConversationObservation,
        where: note.workspace_ref == ^scope.workspace_ref and not is_nil(note.note),
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
    |> within_scope(scope, search_scope)
    |> matching(search)
    |> Repo.all()
    |> authorized_notes(scope)
    |> Enum.map(&document/1)
  end

  defp authorized_notes(notes, scope) do
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

  defp visible_conversations(%{transport: "slack", visibility: :public} = scope) do
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

  defp visible_conversations(scope),
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

  defp text_schema(maximum),
    do: %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => maximum,
      "pattern" => "^[^\\x00]*[^\\s\\x00][^\\x00]*$"
    }
end
