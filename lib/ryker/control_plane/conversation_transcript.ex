defmodule Ryker.ControlPlane.ConversationTranscript do
  @moduledoc """
  The rows of one direct conversation as the messages a reader sees: inputs
  with their revisions, reactions and attachments; accepted replies with their
  cards and generated files; delivered platform messages, among them the
  updates Work posted before its answer; publications; and the quick replies
  routing sent without Work.

  `ConversationProjection` decides which rows are on a page; this module says
  what each row shows, with the sort key and cursor that place it.
  """
  alias Ryker.Artifacts
  alias Ryker.ControlPlane.{ConsolePeople, ConversationTranscript, Paths}
  alias Ryker.ControlPlane.{PublicationPosition, TranscriptCursor}
  alias Ryker.Delivery
  alias Ryker.Episodes
  alias Ryker.Feedback
  alias Ryker.Publication
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work

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
    quick_replies = Map.get(rows, :quick_reply, [])
    item_refs = inputs |> Enum.map(& &1.source_item_ref) |> Enum.filter(&is_binary/1)

    reactions =
      Map.merge(
        routing_reactions(item_refs),
        input_reaction_actions(item_refs),
        fn _item_ref, delivered, acted -> delivered ++ acted end
      )

    # A quick reply or an update is no request's own reply, so its reactions
    # are read from the feedback that names it rather than a request's events.
    message_reactions =
      Feedback.current_reactions(
        "control-plane:lab:" <> conversation_id,
        (actions ++ quick_replies) |> Enum.map(&chat_message_ref/1) |> Enum.filter(&is_binary/1)
      )

    messages =
      compose(
        inputs,
        replies,
        cards(replies),
        output_artifacts(replies, conversation_id),
        reactions,
        Episodes.Reactions.current_for_episodes(Enum.uniq(Enum.map(replies, & &1.episode_id)))
      ) ++
        Enum.flat_map(actions, &action_message(&1, message_reactions)) ++
        publication_messages(publications) ++
        Enum.flat_map(quick_replies, &quick_reply_message(&1, message_reactions))

    messages
    |> attach_execution()
    |> name_authors()
    |> mark_earlier_answers()
    |> Enum.map(&put_cursor(&1, conversation_id))
    |> sort_messages()
  end

  defp put_cursor(%{sort_key: key} = message, conversation_id),
    do: Map.put(message, :cursor, TranscriptCursor.encode(conversation_id, key))

  # The execution an operator message started, as it stands now: the episode's
  # state, or "blocked" when its owning turn is, so a message whose model work
  # stopped says so beside the message and offers the same retry /failures
  # does. Complete work carries nothing; the reply already sits below it.
  #
  # Every message of a request shares its episode, but only the messages its
  # current work answers are being worked on. QA 2026-09-25: while Ryker
  # answered an edited follow-up, "Ryker is working on a reply" also sat under
  # the first message, which had been answered minutes before.
  defp attach_execution(messages) do
    operator = Enum.filter(messages, &(&1.actor == :operator and is_binary(&1[:episode_id])))
    episode_ids = operator |> Enum.map(& &1.episode_id) |> Enum.uniq()
    executions = executions(episode_ids)

    answering =
      executions
      |> Enum.filter(fn {_id, execution} -> execution.state in ["working", "blocked"] end)
      |> Map.new(fn {id, execution} -> {id, execution.active_input_refs} end)
      |> admitted_inputs()
      |> Enum.group_by(fn {{episode_id, _ref}, _input} -> episode_id end, fn {_key, input} ->
        input.native_input_id
      end)

    # Work whose inputs are not recorded is still shown, on the request's newest message.
    newest =
      operator
      |> Enum.group_by(& &1.episode_id)
      |> Map.new(fn {id, owned} -> {id, Enum.max_by(owned, & &1.sort_key).identity} end)

    Enum.map(messages, fn
      %{actor: :operator, episode_id: id} = message when is_binary(id) ->
        execution = Map.get(executions, id)

        Map.put(
          message,
          :execution,
          if(answered?(message, execution, answering, newest),
            do: execution && Map.delete(execution, :active_input_refs)
          )
        )

      message ->
        message
    end)
  end

  # Who sent each of the person's messages, by the name their sign-in gave them,
  # read once for the window: Chat called everyone "You" (Andrew, 2026-10-04:
  # "now when we have tailscale auth why not to properly track user
  # everywhere?"). The console reached without a sign-in is still "You".
  defp name_authors(messages) do
    logins =
      for %{actor: :operator, author_ref: ref} <- messages,
          {:person, login} <- [ConsolePeople.identity(ref)],
          uniq: true,
          do: login

    names = ConsolePeople.names(logins)

    Enum.map(messages, fn
      %{actor: :operator, author_ref: ref} = message ->
        case ConsolePeople.identity(ref) do
          {:person, login} -> Map.put(message, :author, Map.get(names, login, login))
          _local -> Map.put(message, :author, "You")
        end

      message ->
        message
    end)
  end

  defp executions([]), do: %{}

  defp executions(episode_ids) do
    episode_ids
    |> ConversationTranscript.Query.executions()
    |> Repo.all()
    |> Map.new(fn row -> {row.id, Map.delete(row, :id)} end)
  end

  defp answered?(_message, nil, _answering, _newest), do: false

  defp answered?(message, %{state: state}, answering, newest)
       when state in ["working", "blocked"] do
    case Map.fetch(answering, message.episode_id) do
      {:ok, native_ids} -> message.native_input_id in native_ids
      :error -> newest[message.episode_id] == message.identity
    end
  end

  defp answered?(_message, _execution, _answering, _newest), do: true

  # The message and revision each recorded kernel input ref admitted, from the
  # admission the kernel recorded for it: `%{episode_id => refs}` in,
  # `%{{episode_id, ref} => %{native_input_id, revision}}` out.
  defp admitted_inputs(refs_by_episode) do
    refs = refs_by_episode |> Map.values() |> List.flatten() |> Enum.uniq()

    case refs do
      [] ->
        %{}

      [_ | _] ->
        refs_by_episode
        |> admission_events(refs)
        |> Enum.flat_map(&admitted_input(&1, refs_by_episode))
        |> Map.new()
    end
  end

  defp admission_events(refs_by_episode, refs) do
    refs_by_episode
    |> Map.keys()
    |> Episodes.Event.Query.by_episode_ids()
    |> Episodes.Event.Query.admitted_inputs(refs)
    |> Episodes.Event.Query.select_admissions()
    |> Repo.all()
  end

  defp admitted_input({episode_id, ref, payload}, refs_by_episode) do
    with true <- ref in Map.get(refs_by_episode, episode_id, []),
         %{"native_input_id" => native_id, "revision" => revision}
         when is_binary(native_id) and is_integer(revision) <- payload do
      [{{episode_id, ref}, %{native_input_id: native_id, revision: revision}}]
    else
      _other -> []
    end
  end

  # A reply that answered words its message no longer has: the message was
  # edited after the run that wrote the reply chose it. QA 2026-09-25: once
  # the edited question was answered, the earlier reply still sat directly
  # under it with nothing saying it answered the text that was replaced.
  defp mark_earlier_answers(messages) do
    turn_ids =
      for %{actor: :ryker, turn_id: id} <- messages, is_binary(id), uniq: true, do: id

    earlier = earlier_answer_turns(turn_ids)

    Enum.map(messages, fn
      %{actor: :ryker, turn_id: id} = message when is_binary(id) ->
        if MapSet.member?(earlier, id),
          do: Map.put(message, :answered_earlier, true),
          else: message

      message ->
        message
    end)
  end

  defp earlier_answer_turns([]), do: MapSet.new()

  defp earlier_answer_turns(turn_ids) do
    turns =
      turn_ids
      |> Work.Turn.Query.by_ids()
      |> Work.Turn.Query.having_selected_inputs()
      |> Work.Turn.Query.select_selected_inputs()
      |> Repo.all()

    answered =
      turns
      |> Enum.group_by(&elem(&1, 1), &elem(&1, 2))
      |> Map.new(fn {episode_id, refs} -> {episode_id, List.flatten(refs)} end)
      |> admitted_inputs()

    current =
      answered
      |> Map.values()
      |> Enum.map(& &1.native_input_id)
      |> Enum.uniq()
      |> current_revisions()

    for {turn_id, episode_id, refs} <- turns,
        refs
        |> Enum.map(&answered[{episode_id, &1}])
        |> newest_seen()
        |> Enum.any?(&superseded_by_edit?(&1, current)),
        into: MapSet.new(),
        do: turn_id
  end

  # The newest version of each message a run saw. Work resumed by an edit
  # sees both versions of the message and answers the newer one, and its reply
  # read "Answered your earlier wording" (manual test, 2026-10-01).
  defp newest_seen(inputs) do
    inputs
    |> Enum.reject(&is_nil/1)
    |> Enum.group_by(& &1.native_input_id)
    |> Enum.map(fn {_native_id, seen} -> Enum.max_by(seen, & &1.revision) end)
  end

  defp superseded_by_edit?(%{native_input_id: native_id, revision: revision}, current),
    do: match?({newer, :edit} when newer > revision, current[native_id])

  defp current_revisions([]), do: %{}

  defp current_revisions(native_ids) do
    native_ids
    |> ConversationTranscript.Query.current_revisions()
    |> Repo.all()
    |> Map.new()
  end

  defp routing_reactions([]), do: %{}

  defp routing_reactions(item_refs) do
    item_refs
    |> ConversationTranscript.Query.routing_reactions(@page_maximum * 4)
    |> Repo.all()
    |> Enum.filter(&(is_binary(&1.emoji_name) and is_binary(&1.source_item_ref)))
    |> Enum.group_by(& &1.source_item_ref, &Map.delete(&1, :source_item_ref))
  end

  defp input_reaction_actions([]), do: %{}

  defp input_reaction_actions(item_refs) do
    item_refs
    |> ConversationTranscript.Query.work_reactions(@page_maximum * 4)
    |> Repo.all()
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
    refs
    |> Records.Record.Query.by_refs()
    |> Records.Record.Query.limit_to(@record_limit)
    |> Repo.all()
  end

  defp put_card(record, cards, allowed) do
    key = {record.turn_id, record.ref}

    if MapSet.member?(allowed, key),
      do: put_projected_card(record, key, cards),
      else: cards
  end

  defp put_projected_card(record, key, cards) do
    case Delivery.ChatCard.project(record) do
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

  # Names, types and sizes only: a file's bytes are read when someone opens it.
  defp project_output_artifacts(turn_ids, conversation_id) do
    turn_ids
    |> Artifacts.OutputArtifact.Query.by_turn_ids()
    |> Artifacts.OutputArtifact.Query.ordered_by_name()
    |> Artifacts.OutputArtifact.Query.limit_to(@page_maximum * 5)
    |> Artifacts.OutputArtifact.Query.select_listing()
    |> Repo.all()
    |> Map.new(&{{&1.turn_id, &1.ref}, output_artifact(&1, conversation_id)})
  end

  defp output_artifact(artifact, conversation_id) do
    %{
      bytes: artifact.byte_size,
      media_type: artifact.media_type,
      name: artifact.name,
      path: Paths.artifact(conversation_id, artifact.turn_id, artifact.ref),
      ref: artifact.ref,
      status: "available"
    }
  end

  defp compose(
         inputs,
         replies,
         cards,
         artifacts,
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
                attachments: if(deleted, do: [], else: input_attachments(input.content)),
                cards: [],
                editable: not deleted,
                event_kind: input.event_kind,
                item_id: item_id(input.source_item_ref),
                reactions: Map.get(reactions, input.source_item_ref, []),
                ref: input.ref,
                retained: true,
                revision: input.revision,
                state: nil,
                status: input.status,
                text: if(deleted, do: "Message deleted", else: text)
              })
            ]

          # An answer chosen on Ryker's question card is the person's reply.
          # It read "Control plane local · event · revision 1" (Andrew,
          # 2026-10-01), which said nothing to the person who chose it.
          %{
            content: %{"choice" => choice},
            source_kind: "control_plane",
            source_ref: "local"
          }
          when is_binary(choice) ->
            [
              input_identity(input, %{
                actor: :operator,
                attachments: [],
                cards: [],
                editable: false,
                event_kind: input.event_kind,
                item_id: nil,
                reactions: Map.get(reactions, input.source_item_ref, []),
                ref: input.ref,
                retained: true,
                revision: input.revision,
                state: nil,
                status: input.status,
                text: choice
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

    sort_messages(input_messages ++ reply_messages)
  end

  # Position, identity and sort key of one logical input: where its first
  # revision entered the conversation, named by the durable input id.
  # The exact provenance rides along: the current revision's own row id, its
  # episode link and decision, so the page can link this message's own
  # admission or recorded decision, and the native input id so admission
  # progress can sit beside the message that caused it.
  defp input_identity(input, message) do
    Map.merge(message, %{
      author_ref: input.actor_ref,
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
      attachments: [],
      cards: [],
      editable: false,
      event_kind: input.event_kind,
      item_id: item_id(input.source_item_ref),
      reactions: [],
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
      attachments: [],
      cards: [],
      editable: false,
      event_kind: input.event_kind,
      item_id: nil,
      reactions: [],
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
    component = value |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 160)
    if component == "", do: fallback, else: component
  end

  defp marker_component(_value, fallback), do: fallback

  # A delivered platform message: a post a person confirmed, or an update the
  # Work model posted while it worked, placed where it arrived, which for an
  # update is always before the answer that follows it.
  defp action_message(
         %{
           action_ref: action_ref,
           delivered_at: %DateTime{} = delivered_at,
           document: %{"message" => message},
           kind: :message,
           status: :delivered,
           tool: tool
         } = action,
         message_reactions
       )
       when is_binary(action_ref) and is_binary(message) and
              tool in [:post_slack_message, :post_slack_update] do
    message_ref = chat_message_ref(action)

    [
      %{
        actor: :ryker,
        attachments: [],
        cards: [],
        episode_id: action.episode_id,
        feedback_reactions: Map.get(message_reactions, message_ref, []),
        identity: "action:" <> action.id,
        message_ref: message_ref,
        occurred_at: delivered_at,
        reactions: [],
        ref: action_ref,
        retained: true,
        sort_key: TranscriptCursor.key(delivered_at, :action, "action:" <> action.id),
        state: nil,
        status: :delivered,
        text: message
      }
    ]
  end

  defp action_message(_action, _message_reactions), do: []

  # Routing answered the message itself, without Work: no request to open, so
  # the message links the input it answered.
  defp quick_reply_message(%{document: %{"message" => message}} = response, message_reactions)
       when is_binary(message) do
    message_ref = chat_message_ref(response)

    [
      %{
        actor: :ryker,
        attachments: [],
        cards: [],
        episode_id: nil,
        feedback_reactions: Map.get(message_reactions, message_ref, []),
        identity: "quick-reply:" <> response.id,
        input_id: response.input_id,
        message_ref: message_ref,
        occurred_at: response.delivered_at,
        reactions: [],
        ref: response.delivery_ref,
        retained: true,
        sort_key:
          TranscriptCursor.key(response.delivered_at, :quick_reply, "quick-reply:" <> response.id),
        state: nil,
        status: :delivered,
        text: message
      }
    ]
  end

  defp quick_reply_message(_response, _message_reactions), do: []

  # The message a delivered quick reply or update is in Chat, which is what a
  # reaction on it names.
  defp chat_message_ref(%{
         status: :delivered,
         external_receipt: %{"message_ref" => message_ref, "transport" => "control_plane"}
       })
       when is_binary(message_ref),
       do: message_ref

  defp chat_message_ref(_message), do: nil

  defp publication_messages(publications) do
    Enum.flat_map(publications, &publication_message/1)
  end

  defp publication_message(
         {%Publication.Publication{status: status, review_delivery_receipt: receipt} = publication,
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
         {%Publication.Publication{status: :published, published_delivery_receipt: receipt} =
            publication, record_ref}
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
    case Delivery.ChatCard.project_publication(publication, record_ref) do
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
    occurred_at = PublicationPosition.Query.at(publication)
    identity = "publication:" <> publication.id

    %{
      actor: :ryker,
      attachments: [],
      cards: [card],
      identity: identity,
      occurred_at: occurred_at,
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
        attachments: [],
        cards: [],
        episode_id: reply.episode_id,
        feedback_reactions: [],
        generated_files: [],
        identity: "reply:" <> reply.turn_id,
        message_ref: nil,
        occurred_at: reply.occurred_at,
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
        episode_id: reply.episode_id,
        feedback_reactions: Map.get(feedback_reactions, reply.ref, []),
        message_ref: reply_message_ref(reply),
        occurred_at: reply.occurred_at,
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

  # A voice message or video shows with its transcript, or with why it has
  # none.
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
      } = file
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
          |> put_transcript(file)
        ]

      %{"reason" => reason, "status" => "unavailable"} = file when is_binary(reason) ->
        [
          %{bytes: nil, media_type: nil, name: "Attachment", ref: nil, status: reason}
          |> put_transcript(file)
        ]

      _invalid ->
        []
    end)
  end

  defp input_attachments(_content), do: []

  defp put_transcript(attachment, %{"transcript" => words}) when is_binary(words),
    do: Map.put(attachment, :transcript, words)

  defp put_transcript(attachment, %{"transcript_unavailable" => note}) when is_binary(note),
    do: Map.put(attachment, :transcript_unavailable, note)

  defp put_transcript(attachment, _file), do: attachment

  defp reply_outcome(%{"outcome" => %{} = outcome}), do: outcome
  defp reply_outcome(_document), do: %{}

  defp bounded_refs(values) when is_list(values) do
    values
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) <= 1_024))
    |> Enum.take(64)
  end

  defp bounded_refs(_values), do: []
end
