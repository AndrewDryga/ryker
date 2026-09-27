defmodule Ryker.Improvement.Evidence do
  @moduledoc """
  The exact evidence about a candidate's request, as Ryker kept it: the
  person's messages and Ryker's answers in order, each routing decision with
  the exact prompt routing sent and the answer it gave, each Work turn with
  the tools it called and the answer it delivered, and every piece of
  feedback on the request, positive or not.

  Everything is read, never paraphrased, and every stored credential is
  redacted from it (`Ryker.InspectionRedactor`). What a person took back is
  left out: the words of a message they deleted, and any routing prompt that
  quoted it unless its routing example (which forgetting keeps honest) is
  still kept. Expired words are left out too, and each gap is named in
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

  @type t :: %{
          available?: boolean(),
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
  an analysis or a case to rest on.
  """
  @spec gather(Candidate.t(), [String.t()] | nil) :: t()
  def gather(%Candidate{} = candidate, secrets \\ nil) do
    secrets = secrets || InspectionRedactor.configured_secrets()
    request = Candidate.request(candidate)
    episode = episode(request)
    entries = entries(request)
    deleted = deleted_messages(entries)

    messages = Enum.map(entries, &message(&1, deleted, secrets))
    answers = answers(request, entries, secrets)
    {routing, routing_keys} = routing(entries, deleted, secrets)
    work = work(episode, secrets)
    feedback = feedback(request, entries, deleted, secrets)
    person_words? = Enum.any?(messages, &(&1["from"] == "person" and is_binary(&1["text"])))

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
      available?: person_words?,
      request: request_document(candidate, episode, entries),
      conversation: conversation(messages, answers),
      routing: routing,
      work: work,
      feedback: Enum.map(feedback, &Map.delete(&1, :key)),
      omitted: omitted(messages, routing, entries),
      message_keys: keys,
      conversation_refs: conversations
    }
  end

  @doc """
  What an accepted case keeps: the request, the person's messages with who
  sent them and where (so the case can be replayed as a world scenario), the
  answers Ryker gave, each routing decision's exact prompt and answer, and
  the feedback, with the keys forgetting reaches them by. `snapshot` is nil
  when none of the person's words is left.
  """
  @spec case_snapshot(Candidate.t()) :: %{
          snapshot: map() | nil,
          message_keys: [String.t()],
          conversation_refs: [String.t()]
        }
  def case_snapshot(%Candidate{} = candidate) do
    secrets = InspectionRedactor.configured_secrets()
    evidence = gather(candidate, secrets)
    entries = entries(Candidate.request(candidate))
    deleted = deleted_messages(entries)

    events =
      for entry <- entries,
          entry.actor_kind == :user,
          %{"text" => text} when is_binary(text) <- [message(entry, deleted, secrets)],
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
      message_keys: evidence.message_keys,
      conversation_refs: evidence.conversation_refs
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

  defp message(%Entry{} = entry, deleted, secrets) do
    base = %{
      "at" => iso(entry.occurred_at),
      "from" => sender(entry.actor_kind),
      "kind" => Atom.to_string(entry.event_kind)
    }

    cond do
      deleted?(entry, deleted) ->
        Map.merge(base, %{"text" => nil, "note" => "deleted by the person"})

      not is_nil(entry.operational_pruned_at) ->
        Map.merge(base, %{"text" => nil, "note" => "expired"})

      true ->
        Map.put(base, "text", redact(words(entry.content), secrets))
    end
  end

  defp sender(:user), do: "person"
  defp sender(kind), do: Atom.to_string(kind)

  # A message's words: its text, then what was said in each voice message or
  # video it carried.
  defp words(%{} = content) do
    text = if is_binary(content["text"]), do: content["text"], else: ""

    transcripts =
      for %{"transcript" => transcript} when is_binary(transcript) <- List.wrap(content["files"]),
          do: "[voice message] " <> transcript

    [text | transcripts] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")
  end

  defp words(_content), do: ""

  defp event(entry, text) do
    %{
      "at" => iso(entry.occurred_at),
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
  # attempt itself unless a person deleted one of the request's messages
  # (an example is erased with a deleted message it quoted; an attempt is
  # not).
  defp routing(entries, deleted, secrets) do
    decided = entries |> Enum.filter(&(&1.status == :decided)) |> Enum.take(-@routing_limit)
    ids = Enum.map(decided, & &1.id)

    examples =
      Repo.all(from(example in Example, where: example.input_id in ^ids))
      |> Map.new(&{&1.input_id, &1})

    fallback? = MapSet.size(deleted) == 0

    decided
    |> Enum.map(fn entry ->
      case Map.get(examples, entry.id) do
        %Example{forgotten_at: nil} = example ->
          {routing_item(entry, example.prompt, example.answer, example.execution_target, "kept"),
           %{keys: example.message_keys, conversations: example.conversation_refs}}

        %Example{} ->
          {routing_item(entry, nil, nil, nil, "forgotten"), %{keys: [], conversations: []}}

        nil when fallback? ->
          attempt_routing(entry, secrets)

        nil ->
          {routing_item(entry, nil, nil, nil, "withheld"), %{keys: [], conversations: []}}
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
  defp feedback(request, entries, deleted, secrets) do
    asker = entries |> Enum.find(&(&1.actor_kind == :user)) |> then(&(&1 && &1.actor_ref))
    signals = Feedback.for_request(request)
    sources = source_entries(signals)
    deleted = MapSet.union(deleted, deleted_messages(Map.values(sources)))

    Enum.map(signals, fn signal ->
      source = Map.get(sources, signal.source_ref)

      %{
        "at" => iso(signal.occurred_at),
        "kind" => Atom.to_string(signal.kind),
        "value" => signal.value,
        "note" => redact(signal.note, secrets),
        "by" => by(signal, asker),
        "message" => source && message(source, deleted, secrets)["text"],
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
      Enum.any?(messages, &(&1["note"] == "expired")) &&
        "The words of messages older than Ryker keeps them.",
      Enum.any?(routing, &(&1["kept"] == "forgotten")) &&
        "Routing prompts that quoted something a person forgot or deleted.",
      Enum.any?(routing, &(&1["kept"] in ["expired", "withheld"])) &&
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
