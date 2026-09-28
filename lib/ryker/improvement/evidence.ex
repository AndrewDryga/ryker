defmodule Ryker.Improvement.Evidence do
  @moduledoc """
  The exact evidence about a candidate's request, as Ryker kept it: the
  person's messages and Ryker's answers in order, each routing decision with
  the exact prompt routing sent and the answer it gave, each Work turn with
  the tools it called and the answer it delivered, and every piece of
  feedback on the request, positive or not.

  Everything is read, never paraphrased, and every stored credential is
  redacted from it (`Ryker.InspectionRedactor`). What a person took back is
  left out: the words of a message they deleted, the words an edit of theirs
  replaced, and any routing prompt that quoted something a person deleted,
  edited or forgot. Expired words are left out too, and each gap is named in
  `omitted`, so the analysis never mistakes a missing piece for an empty one.

  The analysis reads it through `Ryker.Improvement.Prompt`; accepting a
  candidate freezes part of it as the case's evidence (`case_snapshot/1`).
  `message_keys` and `conversation_refs` name every message, topic and
  conversation it quotes, as routing examples name them, for forgetting.
  """

  import Ecto.Query

  alias Ryker.Admission.Attempt
  alias Ryker.Delivery.{PlatformAction, RoutingResponse}
  alias Ryker.Episodes.Episode
  alias Ryker.Feedback
  alias Ryker.GitHub.Input, as: GitHubInput
  alias Ryker.Improvement.Candidate
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.Repo
  alias Ryker.RoutingExamples
  alias Ryker.RoutingExamples.Example
  alias Ryker.Work.{ActivityEvent, Turn}

  @message_limit 60
  @tool_limit 40
  @routing_limit 8

  @type missing ::
          :improvement_evidence_unavailable
          | :improvement_evidence_wordless
          | :improvement_evidence_automated

  @type t :: %{
          available?: boolean(),
          missing: missing() | nil,
          request: map(),
          conversation: [map()],
          routing: [map()],
          work: [map()],
          feedback: [map()],
          omitted: [String.t()],
          message_keys: [String.t()],
          conversation_refs: [String.t()]
        }

  @doc """
  Gathers the evidence about `candidate`'s request. `available?` is false
  when none of the person's words is left to read: then there is nothing for
  an analysis or a case to rest on, and `missing` says why. The person's
  messages were deleted or have expired (`improvement_evidence_unavailable`),
  they never had words, such as a file, an image or a GitHub review sent
  alone (`improvement_evidence_wordless`), or no person's message is in the
  request at all: an alert, a schedule or an app started it
  (`improvement_evidence_automated`).
  """
  @spec gather(Candidate.t(), [String.t()] | nil) :: t()
  def gather(%Candidate{} = candidate, secrets \\ nil),
    do: read(candidate, secrets || InspectionRedactor.configured_secrets()).evidence

  @doc """
  What an accepted case keeps: the request, the person's messages with who
  sent them and where (so the case can be replayed as a world scenario), the
  answers Ryker gave, each routing decision's exact prompt and answer, and
  the feedback, with the keys forgetting reaches them by. `snapshot` is nil
  when none of the person's words is left, and `missing` says why.
  """
  @spec case_snapshot(Candidate.t()) :: %{
          snapshot: map() | nil,
          missing: missing() | nil,
          message_keys: [String.t()],
          conversation_refs: [String.t()]
        }
  def case_snapshot(%Candidate{} = candidate) do
    %{evidence: evidence, messages: messages} =
      read(candidate, InspectionRedactor.configured_secrets())

    # A revision whose words an edit replaced stays without them, as when the
    # message was first sent: the replay sends it then, in the words the
    # person left (`Ryker.Improvement.Export`).
    events =
      for {entry, %{"text" => text} = said} <- messages,
          entry.actor_kind == :user,
          words?(text) or said["note"] == "edited by the person",
          do: event(entry, text)

    snapshot =
      if evidence.available? and events != [] do
        %{
          "version" => 1,
          "request" => evidence.request,
          "events" => events,
          "conversation" => evidence.conversation,
          "routing" => evidence.routing,
          "feedback" => evidence.feedback
        }
      end

    %{
      snapshot: snapshot,
      missing: evidence.missing,
      message_keys: evidence.message_keys,
      conversation_refs: evidence.conversation_refs
    }
  end

  # One read of everything kept about the request: the evidence, and each of
  # the person's messages it was built from beside what it keeps of it, so a
  # case's events come from the same read as its conversation.
  defp read(candidate, secrets) do
    request = Candidate.request(candidate)
    episode = episode(request)
    entries = entries(request)
    deleted = deleted_messages(entries)
    edited = RoutingExamples.edited_revisions(entries)

    messages = Enum.map(entries, &message(&1, deleted, edited, secrets))
    answers = answers(request, entries, secrets)
    {routing, routing_keys} = routing(entries, deleted, edited, secrets)
    work = work(episode, secrets)
    feedback = feedback(request, entries, deleted, edited, secrets)
    missing = missing(messages)

    keys =
      (Enum.map(entries, &entry_key/1) ++ routing_keys.keys ++ feedback_keys(feedback))
      |> Enum.uniq()
      |> Enum.sort()

    conversations =
      ([candidate.conversation_ref] ++ routing_keys.conversations)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      evidence: %{
        available?: is_nil(missing),
        missing: missing,
        request: request_document(candidate, episode, entries),
        conversation: conversation(messages, answers),
        routing: routing,
        work: work,
        feedback: Enum.map(feedback, &Map.delete(&1, :key)),
        omitted: omitted(messages, routing, entries),
        message_keys: keys,
        conversation_refs: conversations
      },
      messages: Enum.zip(entries, messages)
    }
  end

  # -- The request ------------------------------------------------------------------

  defp episode({:episode, id}), do: Repo.get(Episode, id)
  defp episode(_input), do: nil

  # The person's messages of the request, every revision, oldest first: an
  # episode's are those routing joined to it; a message routing answered by
  # itself is its own.
  defp entries({:episode, id}) do
    Repo.all(
      from(entry in Entry,
        where: entry.episode_id == ^id,
        order_by: [asc: entry.occurred_at, asc: entry.revision, asc: entry.inserted_at],
        limit: @message_limit
      )
    )
  end

  defp entries({:input, id}) do
    Repo.all(from(entry in Entry, where: entry.id == ^id))
  end

  defp request_document(candidate, episode, entries) do
    %{
      "kind" => if(candidate.episode_id, do: "work", else: "quick_reply"),
      "channel" => channel(candidate.transport),
      "state" => request_state(episode, entries),
      "negative_feedback" => candidate.reasons
    }
  end

  defp request_state(%Episode{state: state}, _entries), do: Atom.to_string(state)

  defp request_state(nil, [%Entry{decision_action: action} | _]) when not is_nil(action),
    do: "answered by routing (#{action})"

  defp request_state(nil, _entries), do: "unknown"

  defp channel("slack"), do: "slack"
  defp channel("control_plane"), do: "chat"
  defp channel(transport), do: transport

  # -- Messages ---------------------------------------------------------------------

  # The messages a person deleted, by where they were and which message: every
  # revision of one of those, before or after, keeps no words here.
  defp deleted_messages([]), do: MapSet.new()

  defp deleted_messages(entries) do
    natives =
      entries |> Enum.map(&{&1.source_kind, &1.source_ref, &1.native_input_id}) |> Enum.uniq()

    ids = Enum.map(natives, &elem(&1, 2))

    Repo.all(
      from(entry in Entry,
        where: entry.event_kind == :delete and entry.native_input_id in ^ids,
        select: {entry.source_kind, entry.source_ref, entry.native_input_id}
      )
    )
    |> Enum.filter(&(&1 in natives))
    |> MapSet.new()
  end

  defp deleted?(entry, deleted),
    do: MapSet.member?(deleted, {entry.source_kind, entry.source_ref, entry.native_input_id})

  # `edited` holds the revisions whose words a later edit replaced
  # (`Ryker.RoutingExamples.edited_revisions/1`): the edit keeps its own.
  defp message(%Entry{} = entry, deleted, edited, secrets) do
    base = %{
      "at" => iso(entry.occurred_at),
      "from" => sender(entry.actor_kind),
      "kind" => Atom.to_string(entry.event_kind)
    }

    cond do
      deleted?(entry, deleted) ->
        Map.merge(base, %{"text" => nil, "note" => "deleted by the person"})

      MapSet.member?(edited, entry.id) ->
        Map.merge(base, %{"text" => nil, "note" => "edited by the person"})

      not is_nil(entry.operational_pruned_at) ->
        Map.merge(base, %{"text" => nil, "note" => "expired"})

      true ->
        Map.put(base, "text", redact(words(entry), secrets))
    end
  end

  # Why none of the person's words is left to read, or nil while some are.
  defp missing(messages) do
    people = Enum.filter(messages, &(&1["from"] == "person"))

    cond do
      Enum.any?(people, &words?(&1["text"])) ->
        nil

      people == [] ->
        :improvement_evidence_automated

      Enum.any?(
        people,
        &(&1["note"] in ["deleted by the person", "edited by the person", "expired"])
      ) ->
        :improvement_evidence_unavailable

      true ->
        :improvement_evidence_wordless
    end
  end

  # A message with something to read: a file or an image alone is not one.
  defp words?(text), do: is_binary(text) and String.trim(text) != ""

  defp sender(:user), do: "person"
  defp sender(kind), do: Atom.to_string(kind)

  # A message's words: a GitHub comment's or review's body, as Ryker reads it
  # everywhere (`Ryker.GitHub.Input.body/1`); anything else's text, then what
  # was said in each voice message or video it carried.
  defp words(%Entry{source_kind: "github", content: content}),
    do: GitHubInput.body(content) || ""

  defp words(%Entry{content: %{} = content}) do
    text = if is_binary(content["text"]), do: content["text"], else: ""

    transcripts =
      for %{"transcript" => transcript} when is_binary(transcript) <- List.wrap(content["files"]),
          do: "[voice message] " <> transcript

    [text | transcripts] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  defp words(_entry), do: ""

  # One person's message, with the message it is a revision of: every edit
  # names the message it edits.
  defp event(entry, text) do
    %{
      "at" => iso(entry.occurred_at),
      "message_ref" => entry.source_item_ref || entry.native_input_id,
      "actor" => %{"kind" => Atom.to_string(entry.actor_kind), "ref" => entry.actor_ref},
      "source" => %{"kind" => entry.source_kind, "ref" => entry.source_ref},
      "destination" => %{
        "transport" => entry.destination_transport,
        "conversation_ref" => entry.destination_conversation_ref,
        "thread_ref" => entry.destination_thread_ref
      },
      "event_kind" => Atom.to_string(entry.event_kind),
      "bot_user_ref" => entry.slack_bot_user_ref,
      "text" => text
    }
  end

  defp entry_key(entry),
    do:
      RoutingExamples.message_key(
        entry.destination_conversation_ref,
        entry.source_item_ref || entry.native_input_id
      )

  # -- Ryker's answers --------------------------------------------------------------

  defp answers({:episode, id}, _entries, secrets) do
    replies =
      Repo.all(
        from(turn in Turn,
          where: turn.episode_id == ^id and not is_nil(turn.delivered_at),
          select: {turn.delivered_at, turn.delivery_document}
        )
      )
      |> Enum.map(fn {at, document} -> answer(at, "work_reply", document, secrets) end)

    posts =
      Repo.all(
        from(action in PlatformAction,
          where:
            action.episode_id == ^id and action.kind == :message and action.status == :delivered,
          select: {action.delivered_at, action.document}
        )
      )
      |> Enum.map(fn {at, document} -> answer(at, "posted_update", document, secrets) end)

    replies ++ posts
  end

  defp answers({:input, _id}, entries, secrets) do
    ids = Enum.map(entries, & &1.id)

    Repo.all(
      from(response in RoutingResponse,
        where: response.input_id in ^ids and response.status == :delivered,
        order_by: [asc: response.position],
        select: {response.delivered_at, response.kind, response.document}
      )
    )
    |> Enum.map(fn
      {at, :message, document} -> answer(at, "quick_reply", document, secrets)
      {at, :reaction, document} -> reaction(at, document)
    end)
  end

  defp answer(at, kind, document, secrets) do
    text =
      case document do
        %{"message" => message} when is_binary(message) -> message
        %{"text" => text} when is_binary(text) -> text
        _other -> nil
      end

    %{"at" => iso(at), "from" => "ryker", "kind" => kind, "text" => redact(text, secrets)}
  end

  defp reaction(at, document) do
    emoji = if is_map(document), do: document["emoji_name"]
    %{"at" => iso(at), "from" => "ryker", "kind" => "reaction", "text" => ":#{emoji}:"}
  end

  # The person's messages and Ryker's answers, in the order they happened.
  defp conversation(messages, answers) do
    (messages ++ answers)
    |> Enum.with_index()
    |> Enum.sort_by(fn {item, index} -> {item["at"] || "", index} end)
    |> Enum.map(&elem(&1, 0))
  end

  # -- Routing ----------------------------------------------------------------------

  # Each routing decision about the request's messages: the exact prompt and
  # answer from its routing example when one is kept, else from the routing
  # attempt itself. An example is erased with anything it quoted that a
  # person forgot, deleted or edited; an attempt is not, so its prompt is
  # read only when nothing it quotes (the message, its thread and channel,
  # learned notes and topics) was forgotten, deleted or edited, by the test an
  # example's copy passes (`Ryker.RoutingExamples.quotes_forgotten?/1`).
  defp routing(entries, deleted, edited, secrets) do
    decided = entries |> Enum.filter(&(&1.status == :decided)) |> Enum.take(-@routing_limit)
    ids = Enum.map(decided, & &1.id)

    examples =
      Repo.all(from(example in Example, where: example.input_id in ^ids))
      |> Map.new(&{&1.input_id, &1})

    decided
    |> Enum.map(fn entry ->
      case Map.get(examples, entry.id) do
        %Example{forgotten_at: nil} = example ->
          {routing_item(entry, example.prompt, example.answer, example.execution_target, "kept"),
           %{keys: example.message_keys, conversations: example.conversation_refs}}

        %Example{} ->
          {routing_item(entry, nil, nil, nil, "forgotten"), %{keys: [], conversations: []}}

        nil ->
          unkept_routing(entry, deleted, edited, secrets)
      end
    end)
    |> then(fn items ->
      {Enum.map(items, &elem(&1, 0)),
       %{
         keys: Enum.flat_map(items, &elem(&1, 1).keys),
         conversations: Enum.flat_map(items, &elem(&1, 1).conversations)
       }}
    end)
  end

  defp unkept_routing(entry, deleted, edited, secrets) do
    if MapSet.size(deleted) == 0 and MapSet.size(edited) == 0 and
         not RoutingExamples.quotes_forgotten?(entry),
       do: attempt_routing(entry, secrets),
       else: {routing_item(entry, nil, nil, nil, "forgotten"), %{keys: [], conversations: []}}
  end

  defp attempt_routing(entry, secrets) do
    attempt =
      Repo.one(
        from(attempt in Attempt,
          where:
            attempt.input_id == ^entry.id and
              attempt.generation == ^entry.execution_generation and
              attempt.phase == "committed" and is_nil(attempt.operational_pruned_at)
        )
      )

    case attempt do
      %Attempt{submission: %{"prompt" => prompt}, response: %{"assistant_message" => answer}}
      when is_binary(prompt) and is_binary(answer) ->
        {routing_item(
           entry,
           redact(prompt, secrets),
           redact(answer, secrets),
           attempt.execution_target,
           "attempt"
         ), RoutingExamples.quoted_keys(entry)}

      _pruned_or_absent ->
        {routing_item(entry, nil, nil, nil, "expired"), %{keys: [], conversations: []}}
    end
  end

  defp routing_item(entry, prompt, answer, target, source) do
    %{
      "message_at" => iso(entry.occurred_at),
      "decision" => entry.decision_action && Atom.to_string(entry.decision_action),
      "model" => target,
      "prompt" => prompt,
      "answer" => answer,
      "kept" => source
    }
  end

  # -- Work -------------------------------------------------------------------------

  defp work(nil, _secrets), do: []

  defp work(%Episode{id: id}, secrets) do
    turns =
      Repo.all(
        from(turn in Turn,
          where: turn.episode_id == ^id,
          order_by: [asc: turn.inserted_at, asc: turn.id]
        )
      )

    tools = tools(id)

    Enum.map(turns, fn turn ->
      document = if is_map(turn.delivery_document), do: turn.delivery_document, else: %{}

      %{
        "started_at" => iso(turn.inserted_at),
        "status" => Atom.to_string(turn.status),
        "error" => turn.last_error_code,
        "model" => turn.execution_target,
        "outcome" => get_in(document, ["outcome", "state"]),
        "answer" => redact(document["message"], secrets),
        "tools" => Map.get(tools, turn.coop_turn_id, [])
      }
    end)
  end

  # The tools each turn called, in order, with how each call ended: a
  # server's tool by name, or what the worker was doing (such as starting a
  # tool server) when it names no tool.
  defp tools(episode_id) do
    rows =
      Repo.all(
        from(event in ActivityEvent,
          where:
            event.episode_id == ^episode_id and event.kind in ["tool.started", "tool.completed"] and
              is_nil(event.operational_pruned_at),
          order_by: [asc: event.occurred_at, asc: event.sequence],
          select: {event.coop_turn_id, event.kind, event.payload}
        )
      )

    endings =
      for {_turn, "tool.completed", %{"tool_call_id" => call} = payload} <- rows,
          into: %{},
          do: {call, payload["status"]}

    rows
    |> Enum.flat_map(fn
      {turn, "tool.started", %{"tool_call_id" => call} = payload} ->
        [
          {turn,
           %{"tool" => tool_name(payload), "status" => Map.get(endings, call, "unfinished")}}
        ]

      _completed ->
        []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {turn, calls} -> {turn, Enum.take(calls, -@tool_limit)} end)
  end

  defp tool_name(%{"input" => %{"server" => server, "tool" => tool}})
       when is_binary(server) and is_binary(tool),
       do: "#{server}.#{tool}"

  defp tool_name(%{"tool_call_id" => call}), do: call

  # -- Feedback ---------------------------------------------------------------------

  # Every signal about the request, oldest first, with the words of the message
  # it came from when it came from one: the message that asked again, the edit,
  # or the message routing read a feeling from.
  defp feedback(request, entries, deleted, edited, secrets) do
    asker = entries |> Enum.find(&(&1.actor_kind == :user)) |> then(&(&1 && &1.actor_ref))
    signals = Feedback.for_request(request)
    sources = source_entries(signals)
    deleted = MapSet.union(deleted, deleted_messages(Map.values(sources)))
    edited = MapSet.union(edited, RoutingExamples.edited_revisions(Map.values(sources)))

    Enum.map(signals, fn signal ->
      source = Map.get(sources, signal.source_ref)

      %{
        "at" => iso(signal.occurred_at),
        "kind" => Atom.to_string(signal.kind),
        "value" => signal.value,
        "note" => redact(signal.note, secrets),
        "by" => by(signal, asker),
        "message" => source && message(source, deleted, edited, secrets)["text"],
        key: source && entry_key(source)
      }
    end)
  end

  defp source_entries(signals) do
    ids =
      for %{source_ref: "ingress-input:" <> id} <- signals,
          {:ok, id} <- [Ecto.UUID.cast(id)],
          do: id

    Repo.all(from(entry in Entry, where: entry.id in ^ids))
    |> Map.new(&{Inbox.ref(&1), &1})
  end

  defp by(%{kind: :reviewed}, _asker), do: "operator"
  defp by(%{actor_ref: actor}, actor), do: "the person who asked"
  defp by(_signal, _asker), do: "someone else"

  defp feedback_keys(feedback), do: for(%{key: key} when is_binary(key) <- feedback, do: key)

  # -- Gaps -------------------------------------------------------------------------

  defp omitted(messages, routing, entries) do
    [
      Enum.any?(messages, &(&1["note"] == "deleted by the person")) &&
        "The words of messages the person deleted.",
      Enum.any?(messages, &(&1["note"] == "edited by the person")) &&
        "The words messages had before the person edited them.",
      Enum.any?(messages, &(&1["note"] == "expired")) &&
        "The words of messages older than Ryker keeps them.",
      Enum.any?(routing, &(&1["kept"] == "forgotten")) &&
        "Routing prompts that quoted something a person forgot, edited or deleted.",
      Enum.any?(routing, &(&1["kept"] == "expired")) &&
        "Routing prompts that were no longer kept.",
      length(entries) >= @message_limit && "Messages after the first #{@message_limit}."
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp redact(nil, _secrets), do: nil
  defp redact(text, secrets) when is_binary(text), do: InspectionRedactor.redact(text, secrets)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = at), do: at |> DateTime.truncate(:microsecond) |> DateTime.to_iso8601()

  defp iso(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
end
