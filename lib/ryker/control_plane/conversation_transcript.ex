defmodule Ryker.ControlPlane.ConversationTranscript do
  @moduledoc """
  The rows of one direct conversation as the messages a reader sees: inputs
  with their revisions, reactions and attachments; accepted replies with their
  cards and generated files; delivered platform messages; and publications.

  `ConversationProjection` decides which rows are on a page; this module says
  what each row shows, with the sort key and cursor that place it.
  """

  import Ecto.Query

  alias Ryker.Artifacts.OutputArtifact
  alias Ryker.ControlPlane.{Card, TranscriptCursor}
  alias Ryker.Delivery.{PlatformAction, Reaction}
  alias Ryker.Episodes.{Episode, Reactions}
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.State.Record
  alias Ryker.Work.Turn

  @page_maximum 200
  @record_limit 64

  @doc """
  The messages for one window of candidate rows, in display order, each with
  its cursor and, for an operator message, the current state of the execution
  it started.
  """
  def messages(window, conversation_id) do
    rows = Enum.group_by(window, &elem(&1, 1), &elem(&1, 2))
    inputs = Map.get(rows, :input, [])
    replies = Map.get(rows, :reply, [])
    actions = Map.get(rows, :action, [])
    publications = Map.get(rows, :publication, [])
    item_refs = inputs |> Enum.map(& &1.source_item_ref) |> Enum.filter(&is_binary/1)

    reactions =
      Map.merge(
        delivery_reactions(item_refs),
        input_reaction_actions(item_refs),
        fn _item_ref, delivered, acted -> delivered ++ acted end
      )

    messages =
      compose(
        inputs,
        replies,
        cards(replies),
        output_artifacts(replies, conversation_id),
        actions,
        reactions,
        Reactions.current_for_episodes(Enum.uniq(Enum.map(replies, & &1.episode_id)))
      ) ++ publication_messages(publications)

    messages
    |> attach_execution()
    |> Enum.map(&put_cursor(&1, conversation_id))
    |> sort_messages()
  end

  defp put_cursor(%{sort_key: key} = message, conversation_id),
    do: Map.put(message, :cursor, TranscriptCursor.encode(conversation_id, key))

  # The execution an operator message started, as it stands now: the episode's
  # state, or "blocked" when its owning turn is, so a message whose model work
  # stopped says so beside the message and offers the same retry /failures
  # does. Complete work carries nothing; the reply already sits below it.
  defp attach_execution(messages) do
    episode_ids =
      messages
      |> Enum.filter(&(&1.actor == :operator and is_binary(&1[:episode_id])))
      |> Enum.map(& &1.episode_id)
      |> Enum.uniq()

    executions =
      if episode_ids == [] do
        %{}
      else
        Repo.all(
          from(episode in Episode,
            left_join: turn in Turn,
            on:
              turn.episode_id == episode.id and turn.turn_ref == episode.owner_ref and
                episode.owner_kind == :turn,
            where: episode.id in ^episode_ids,
            select: %{
              id: episode.id,
              key: episode.key,
              state:
                fragment(
                  "CASE WHEN ? = 'blocked' THEN 'blocked' ELSE ?::text END",
                  turn.status,
                  episode.state
                )
            }
          )
        )
        |> Map.new(fn row -> {row.id, %{key: row.key, state: row.state}} end)
      end

    Enum.map(messages, fn message ->
      case message do
        %{actor: :operator, episode_id: id} when is_binary(id) ->
          Map.put(message, :execution, Map.get(executions, id))

        _other ->
          message
      end
    end)
  end

  defp delivery_reactions([]), do: %{}

  defp delivery_reactions(item_refs) do
    Repo.all(
      from(reaction in Reaction,
        where: reaction.transport == "control_plane" and reaction.source_item_ref in ^item_refs,
        order_by: [asc: reaction.inserted_at, asc: reaction.id],
        limit: ^(@page_maximum * 4),
        select: %{
          delivery_ref: reaction.delivery_ref,
          emoji_name: fragment("(?::jsonb ->> 'emoji_name')", reaction.document),
          source_item_ref: reaction.source_item_ref,
          status: reaction.status
        }
      )
    )
    |> Enum.filter(&(is_binary(&1.emoji_name) and is_binary(&1.source_item_ref)))
    |> Enum.group_by(& &1.source_item_ref, &Map.delete(&1, :source_item_ref))
  end

  defp input_reaction_actions([]), do: %{}

  defp input_reaction_actions(item_refs) do
    Repo.all(
      from(action in PlatformAction,
        where:
          action.transport == "control_plane" and action.kind == :reaction and
            action.source_item_ref in ^item_refs,
        order_by: [asc: action.inserted_at, asc: action.id],
        limit: ^(@page_maximum * 4),
        select: %{
          action_ref: action.action_ref,
          document: action.document,
          source_item_ref: action.source_item_ref,
          status: action.status
        }
      )
    )
    |> Enum.filter(&(is_map(&1.document) and is_binary(&1.document["emoji_name"])))
    |> Enum.group_by(& &1.source_item_ref, fn action ->
      %{
        delivery_ref: action.action_ref,
        emoji_name: action.document["emoji_name"],
        status: action.status
      }
    end)
  end

  defp cards(replies) do
    pairs = card_pairs(replies)

    refs = Enum.map(pairs, &elem(&1, 1))
    allowed = MapSet.new(pairs)

    refs
    |> card_records()
    |> Enum.reduce(%{}, &put_card(&1, &2, allowed))
  end

  defp card_pairs(replies) do
    replies
    |> Enum.reverse()
    |> Enum.flat_map(fn reply ->
      reply.document
      |> reply_outcome()
      |> Map.get("record_refs", [])
      |> bounded_refs()
      |> Enum.map(&{reply.turn_id, &1})
    end)
    |> Enum.uniq()
    |> Enum.take(@record_limit)
  end

  defp card_records([]), do: []

  defp card_records(refs) do
    Repo.all(
      from(record in Record,
        where: record.ref in ^refs,
        limit: @record_limit
      )
    )
  end

  defp put_card(record, cards, allowed) do
    key = {record.turn_id, record.ref}

    if MapSet.member?(allowed, key),
      do: put_projected_card(record, key, cards),
      else: cards
  end

  defp put_projected_card(record, key, cards) do
    case Card.project(record) do
      {:ok, card} -> Map.put(cards, key, card)
      :ignore -> cards
    end
  end

  defp output_artifacts(replies, conversation_id) do
    replies
    |> Enum.map(& &1.turn_id)
    |> Enum.uniq()
    |> project_output_artifacts(conversation_id)
  end

  defp project_output_artifacts([], _conversation_id), do: %{}

  defp project_output_artifacts(turn_ids, conversation_id) do
    Repo.all(
      from(artifact in OutputArtifact,
        where: artifact.turn_id in ^turn_ids,
        order_by: [asc: artifact.name, asc: artifact.ref],
        limit: ^(@page_maximum * 5)
      )
    )
    |> Map.new(&{{&1.turn_id, &1.ref}, output_artifact(&1, conversation_id)})
  end

  defp output_artifact(artifact, conversation_id) do
    %{
      bytes: artifact.byte_size,
      media_type: artifact.media_type,
      name: artifact.name,
      path:
        "/conversations/#{conversation_id}/turns/#{artifact.turn_id}/artifacts/#{URI.encode(artifact.ref, &URI.char_unreserved?/1)}",
      ref: artifact.ref,
      status: "available"
    }
  end

  defp compose(
         inputs,
         replies,
         cards,
         artifacts,
         actions,
         reactions,
         feedback_reactions
       ) do
    input_messages =
      Enum.flat_map(inputs, fn input ->
        case input do
          %{pruned_at: %DateTime{}, source_kind: "control_plane", source_ref: "local"} ->
            [expired_input_message(input)]

          %{
            content: %{"text" => text},
            source_kind: "control_plane",
            source_ref: "local"
          }
          when is_binary(text) ->
            deleted = input.event_kind == :delete

            [
              input_identity(input, %{
                actor: :operator,
                artifact_refs: if(deleted, do: [], else: input_artifact_refs(input.content)),
                attachments: if(deleted, do: [], else: input_attachments(input.content)),
                cards: [],
                editable: not deleted,
                event_kind: input.event_kind,
                item_id: item_id(input.source_item_ref),
                reactions: Map.get(reactions, input.source_item_ref, []),
                record_refs: [],
                ref: input.ref,
                retained: true,
                revision: input.revision,
                state: nil,
                status: input.status,
                text: if(deleted, do: "Message deleted", else: text)
              })
            ]

          %{source_kind: source_kind, source_ref: source_ref}
          when is_binary(source_kind) and is_binary(source_ref) ->
            [integration_message(input)]

          _invalid_source ->
            []
        end
      end)

    reply_messages =
      Enum.flat_map(replies, &reply_message(&1, cards, artifacts, feedback_reactions))

    action_messages = Enum.flat_map(actions, &action_message/1)

    sort_messages(input_messages ++ reply_messages ++ action_messages)
  end

  # Position, identity and sort key of one logical input: where its first
  # revision entered the conversation, named by the durable input id.
  # The exact provenance rides along: the current revision's own row id, its
  # episode link and decision, so the page can link this message's own
  # admission or recorded decision, and the native input id so admission
  # progress can sit beside the message that caused it.
  defp input_identity(input, message) do
    Map.merge(message, %{
      decision_action: input.decision_action,
      edited_at: if(input.revision > 1, do: input.edited_at),
      episode_id: input.episode_id,
      identity: "input:" <> input.native_input_id,
      input_id: input.id,
      native_input_id: input.native_input_id,
      occurred_at: input.position,
      sort_key: TranscriptCursor.key(input.position, :input, "input:" <> input.native_input_id)
    })
  end

  # Retention replaced the body. The row stays where the message was so the
  # transcript never reads as shorter than it was, and nothing can edit it.
  defp expired_input_message(input) do
    input_identity(input, %{
      actor: :operator,
      artifact_refs: [],
      attachments: [],
      cards: [],
      editable: false,
      event_kind: input.event_kind,
      item_id: item_id(input.source_item_ref),
      reactions: [],
      record_refs: [],
      ref: input.ref,
      retained: false,
      revision: input.revision,
      state: nil,
      status: input.status,
      text: "This message expired under retention."
    })
  end

  defp integration_message(input) do
    event_type =
      case input.content do
        %{"event_type" => value} when is_binary(value) -> marker_component(value, "event")
        _other -> input.event_kind |> Atom.to_string() |> marker_component("event")
      end

    input_identity(input, %{
      actor: :integration,
      artifact_refs: [],
      attachments: [],
      cards: [],
      editable: false,
      event_kind: input.event_kind,
      item_id: nil,
      reactions: [],
      record_refs: [],
      ref: input.ref,
      retained: is_nil(input.pruned_at),
      revision: input.revision,
      state: nil,
      status: input.status,
      text:
        "#{source_label(input.source_kind)} #{marker_component(input.source_ref, "integration")} · #{event_type} · revision #{input.revision}"
    })
  end

  defp source_label("webhook"), do: "Webhook"

  defp source_label(source_kind) do
    source_kind
    |> marker_component("Integration")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp marker_component(value, fallback) when is_binary(value) do
    case value |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 160) do
      "" -> fallback
      component -> component
    end
  end

  defp marker_component(_value, fallback), do: fallback

  defp action_message(
         %{
           action_ref: action_ref,
           delivered_at: %DateTime{} = delivered_at,
           document: %{"message" => message},
           kind: :message,
           status: :delivered,
           tool: :post_slack_message
         } = action
       )
       when is_binary(action_ref) and is_binary(message) do
    [
      %{
        actor: :ryker,
        artifact_refs: [],
        attachments: [],
        cards: [],
        episode_ref: action.episode_ref,
        identity: "action:" <> action.id,
        occurred_at: delivered_at,
        reactions: [],
        record_refs: [],
        ref: action_ref,
        retained: true,
        sort_key: TranscriptCursor.key(delivered_at, :action, "action:" <> action.id),
        state: nil,
        status: :delivered,
        text: message
      }
    ]
  end

  defp action_message(_action), do: []

  defp publication_messages(publications) do
    Enum.flat_map(publications, &publication_message/1)
  end

  defp publication_message(
         {%Publication{status: status, review_delivery_receipt: receipt} = publication,
          record_ref}
       )
       when status in [:reviewed, :blocked] and is_map(receipt) do
    project_publication_message(
      publication,
      record_ref,
      receipt,
      publication_review_message(status)
    )
  end

  defp publication_message(
         {%Publication{status: :published, published_delivery_receipt: receipt} = publication,
          record_ref}
       )
       when is_map(receipt) do
    project_publication_message(
      publication,
      record_ref,
      receipt,
      "Published the exact reviewed candidate as a draft pull request."
    )
  end

  defp publication_message(_not_delivered), do: []

  defp project_publication_message(publication, record_ref, receipt, message) do
    case Card.project_publication(publication, record_ref) do
      {:ok, card} -> [build_publication_message(publication, receipt, card, message)]
      :ignore -> []
    end
  end

  defp publication_review_message(:reviewed) do
    "The committed change passed trusted review. Publish this exact candidate only after reviewing the host-owned details."
  end

  defp publication_review_message(:blocked) do
    "The committed change is not publishable. Review the trusted findings below."
  end

  defp build_publication_message(publication, receipt, card, message) do
    occurred_at = publication_position(publication)
    identity = "publication:" <> publication.id

    %{
      actor: :ryker,
      artifact_refs: [],
      attachments: [],
      cards: [card],
      identity: identity,
      occurred_at: occurred_at,
      record_refs: [],
      ref: receipt["delivery_ref"],
      retained: true,
      sort_key: TranscriptCursor.key(occurred_at, :publication, identity),
      state: nil,
      status: publication.status,
      text: message
    }
  end

  defp sort_messages(messages), do: Enum.sort_by(messages, & &1.sort_key)

  # Retention replaced the delivered document. The reply keeps its place in
  # the transcript so the answer's absence is visible as retention, not as a
  # question nobody answered.
  defp reply_message(
         %{document: %{"retention" => "pruned"}, pruned_at: %DateTime{}} = reply,
         _cards,
         _artifacts,
         _feedback_reactions
       ) do
    [
      %{
        actor: :ryker,
        artifact_refs: [],
        attachments: [],
        cards: [],
        episode_ref: reply.episode_ref,
        feedback_reactions: [],
        generated_files: [],
        identity: "reply:" <> reply.turn_id,
        message_ref: nil,
        occurred_at: reply.occurred_at,
        record_refs: [],
        ref: reply.ref,
        retained: false,
        sort_key: TranscriptCursor.key(reply.occurred_at, :reply, "reply:" <> reply.turn_id),
        state: nil,
        status: reply.status,
        text: "This reply expired under retention.",
        turn_id: reply.turn_id
      }
    ]
  end

  defp reply_message(
         %{document: %{"message" => text} = document} = reply,
         cards,
         artifacts,
         feedback_reactions
       )
       when is_binary(text) do
    outcome = reply_outcome(document)
    record_refs = bounded_refs(outcome["record_refs"])
    artifact_refs = bounded_refs(outcome["artifact_refs"])

    [
      %{
        actor: :ryker,
        artifact_refs: artifact_refs,
        identity: "reply:" <> reply.turn_id,
        retained: true,
        sort_key: TranscriptCursor.key(reply.occurred_at, :reply, "reply:" <> reply.turn_id),
        generated_files:
          artifacts
          |> Enum.filter(fn {{turn_id, ref}, _artifact} ->
            turn_id == reply.turn_id and ref not in artifact_refs
          end)
          |> Enum.map(&elem(&1, 1))
          |> Enum.sort_by(& &1.name),
        attachments:
          Enum.flat_map(artifact_refs, fn ref ->
            case Map.get(artifacts, {reply.turn_id, ref}) do
              %{} = artifact -> [artifact]
              _missing -> []
            end
          end),
        cards:
          Enum.flat_map(record_refs, fn ref ->
            case Map.get(cards, {reply.turn_id, ref}) do
              %{} = card -> [card]
              _missing -> []
            end
          end),
        episode_ref: reply.episode_ref,
        feedback_reactions: Map.get(feedback_reactions, reply.ref, []),
        message_ref: reply_message_ref(reply),
        occurred_at: reply.occurred_at,
        record_refs: record_refs,
        ref: reply.ref,
        state: outcome["state"],
        status: reply.status,
        text: text,
        turn_id: reply.turn_id
      }
    ]
  end

  defp reply_message(_not_visible_reply, _cards, _artifacts, _feedback_reactions), do: []

  defp reply_message_ref(%{
         status: :settled,
         external_receipt: %{
           "conversation_ref" => conversation_ref,
           "message_ref" => message_ref,
           "transport" => "control_plane"
         }
       })
       when is_binary(conversation_ref) and is_binary(message_ref),
       do: message_ref

  defp reply_message_ref(_reply), do: nil

  defp item_id("control-plane-item:" <> item_id) do
    case Ecto.UUID.cast(item_id) do
      {:ok, normalized} -> normalized
      :error -> nil
    end
  end

  defp item_id(_source_item_ref), do: nil

  defp input_artifact_refs(content) do
    content
    |> input_attachments()
    |> Enum.flat_map(fn
      %{ref: ref, status: "available"} when is_binary(ref) -> [ref]
      _unavailable -> []
    end)
  end

  defp input_attachments(%{"files" => files}) when is_list(files) do
    files
    |> Enum.take(2)
    |> Enum.flat_map(fn
      %{
        "artifact_ref" => ref,
        "bytes" => bytes,
        "media_type" => media_type,
        "name" => name,
        "status" => "available"
      }
      when is_binary(ref) and is_integer(bytes) and bytes > 0 and is_binary(media_type) and
             is_binary(name) ->
        [
          %{
            bytes: bytes,
            media_type: media_type,
            name: name,
            ref: ref,
            status: "available"
          }
        ]

      %{"reason" => reason, "status" => "unavailable"} when is_binary(reason) ->
        [%{bytes: nil, media_type: nil, name: "Attachment", ref: nil, status: reason}]

      _invalid ->
        []
    end)
  end

  defp input_attachments(_content), do: []

  defp reply_outcome(%{"outcome" => %{} = outcome}), do: outcome
  defp reply_outcome(_document), do: %{}

  defp bounded_refs(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 1_024))
    |> Enum.take(64)
  end

  defp bounded_refs(_values), do: []

  @doc "The delivery a publication currently shows; the cursor is placed at it."
  def publication_position(publication) do
    if publication.status == :published,
      do: publication.published_at || publication.updated_at || publication.inserted_at,
      else: publication.reviewed_at || publication.updated_at || publication.inserted_at
  end
end
