defmodule Ryker.RoutingExamples do
  @moduledoc """
  Routing decisions kept for training a smaller routing model.

  While a person keeps "Keep routing examples for training" on (Settings ›
  Data retention), each routing decision is copied once it has settled:
  routing committed it and nothing it started is still running. The Work it
  started or joined has come to rest (`Ryker.Work.OwningTurn.Query.work_rest/0`,
  the rest Learning waits for), and each quick reply or reaction it chose was
  delivered or gave up. Its outcome is known then, and its bodies are still
  there: they are pruned only after that Work's sessions are discarded.

  The copy holds the exact prompt routing sent and the model's answer, both
  redacted (`Ryker.InspectionRedactor.redact/2`, with every stored credential
  among the values it removes), the answers routing refused before that one
  with why, the decision and what happened next as labels, and the tokens and
  cost. It names the message and the request it came from without a foreign
  key, so the operational, history and audit horizons never reach it; only
  its own window does (`Ryker.Retention.Data`). The feedback people give on
  its request is copied beside it as it arrives (`copy_feedback/0`), since
  feedback itself expires at the operational horizon.

  A person forgetting wins. Forgetting a fact or a learned topic, deleting a
  message in Slack, editing its words, or deleting a Slack channel erases
  every example whose prompt quoted that message, topic or conversation, in
  the same transaction, what improvement candidates hold about it
  (`Ryker.Improvement`), the local routing comparisons of such a prompt
  (`Ryker.LocalRouting`), and the work examples of a request asked in it or
  whose routing quoted it (`Ryker.WorkExamples`). A person's edit takes back the words it replaced;
  one that left them as they were, as Slack reports a link's preview
  arriving, takes back nothing, and so does an app updating its own message,
  as an alert does when it resolves. An erased example keeps only its
  identity, so it is never copied again. One whose message was forgotten
  before its turn to be copied is checked at the copy, which then records
  only that identity. Each copy and each forgetting holds one lock (shared by
  copies, exclusive to forgetting), so a copy in flight can never slip past a
  forgetting that is committing.

  What the prompt quotes and forgetting can reach: the message itself, the
  earlier messages of its thread or channel, learned observations and topics,
  and the messages previewed for each earlier request offered as a candidate
  (`Ryker.Admission.Candidate.previewed_messages/1`). A decision routed before
  those were recorded (2026-09-28) names none, so its previews stay untraced.
  """
  alias Ryker.Admission
  alias Ryker.AdvisoryLock
  alias Ryker.CanonicalJSON
  alias Ryker.ConversationRef
  alias Ryker.Delivery
  alias Ryker.Episodes
  alias Ryker.Improvement
  alias Ryker.Ingress
  alias Ryker.InspectionRedactor
  alias Ryker.Knowledge
  alias Ryker.Learning
  alias Ryker.LocalRouting
  alias Ryker.Repo
  alias Ryker.RoutingExamples.{Example, Feedback}
  alias Ryker.Settings
  alias Ryker.Slack
  alias Ryker.TrainingExamples
  alias Ryker.UTCDateTime
  alias Ryker.Work
  alias Ryker.WorkExamples

  @lock "ryker-routing-examples"
  # What forgetting empties; the example keeps its identity.
  @bodies [:prompt, :output_schema, :answer, :rejected_answers, :decision, :outcome, :usage]

  @type capture_result :: %{
          copied: non_neg_integer(),
          forgotten: non_neg_integer(),
          failed: [Ecto.UUID.t()]
        }

  # -- Copying -------------------------------------------------------------------

  @doc """
  Copies up to `batch_size` settled routing decisions decided within
  `window_seconds` that have no example yet, redacting the value of every
  saved credential beside the values `Ryker.InspectionRedactor.configured_secrets/0`
  names.

  `copied` counts the examples kept and `forgotten` those taken as identity
  only, because a message they quote was forgotten first. Nothing is copied
  while keeping routing examples is off.
  """
  @spec capture(map()) :: {:ok, capture_result()}
  def capture(%{batch_size: batch_size, window_seconds: window_seconds} = options)
      when is_integer(batch_size) and batch_size > 0 and is_integer(window_seconds) and
             window_seconds > 0 do
    secrets = InspectionRedactor.current_secrets()

    results =
      batch_size
      |> settled_inputs(window_seconds, Map.get(options, :skip, []))
      |> Enum.map(&{&1, copy(&1, secrets)})

    {:ok, _copied} = copy_feedback()
    {:ok, TrainingExamples.counts(results)}
  end

  @doc """
  Copies each feedback signal about a kept example's request, or about the
  message routing answered by itself, beside the example once
  (`Ryker.RoutingExamples.Feedback`), and returns how many it copied. A
  reaction is about the one message it is on, so it is copied only beside
  the decision that sent that message.

  Feedback arrives before and after an example is copied (a reaction the
  next day, a rating when the request ends), and expires at the operational
  horizon while the example stays for its own window, so every pass copies
  what is new. Only the kind, value, category and time are copied; never who
  gave it or a note's words. It holds the lock a copy holds, so a forgetting
  either committed first, and the example it emptied is skipped, or waits and
  removes what this copied.
  """
  @spec copy_feedback() :: {:ok, non_neg_integer()}
  def copy_feedback,
    do: TrainingExamples.copy_feedback(&enabled?/0, Feedback, Feedback.Query.copies_of_signals())

  # A decided message whose routing turn completed and was committed, whose
  # bodies are still kept, with no example yet, and with nothing it started
  # still running. Taken oldest first.
  defp settled_inputs(limit, window_seconds, skip),
    do: limit |> Example.Query.settled_decisions(window_seconds, skip) |> Repo.all()

  defp copy(input_id, secrets) do
    TrainingExamples.copy("routing example", "input=#{input_id}", fn ->
      copy_in_transaction(input_id, secrets)
    end)
  end

  defp copy_in_transaction(input_id, secrets) do
    Repo.transaction(fn ->
      # The message is held first and the lock second, the order a deletion
      # recording its revision takes them in, so the two cannot wait on each
      # other.
      with true <- enabled?(),
           {:ok, %Ingress.Inbox.Entry{} = entry} <- held_input(input_id),
           {:ok, %Admission.Attempt{} = attempt} <- committed_attempt(entry),
           :ok <- lock(:shared),
           false <- Repo.exists?(Example.Query.by_input_id(input_id)) do
        entry |> example(attempt, secrets) |> TrainingExamples.insert!([:input_id])
      else
        _nothing_to_copy -> :skipped
      end
    end)
  end

  defp enabled? do
    enabled =
      Settings.Retention.Query.select_routing_examples_enabled()
      |> Settings.Retention.Query.lock_for_share()
      |> Repo.one()

    enabled == true
  end

  defp held_input(input_id) do
    input_id
    |> Ingress.Inbox.Entry.Query.by_id()
    |> Ingress.Inbox.Entry.Query.decided_with_bodies()
    |> Ingress.Inbox.Entry.Query.lock_for_share()
    |> Repo.fetch()
  end

  defp committed_attempt(entry),
    do: entry |> Admission.Attempt.Query.committed_for() |> Repo.fetch()

  defp example(entry, attempt, secrets) do
    now = Repo.now!()
    prompt = attempt.submission["prompt"]
    document = decoded(prompt)
    quoted = quoted(entry)
    episode = entry.episode_id && Repo.one(Episodes.Episode.Query.by_id(entry.episode_id))

    identity = %Example{
      id: Repo.generate_id(),
      input_id: entry.id,
      episode_id: entry.episode_id,
      episode_ref: episode && episode.key,
      source_identity: Learning.Observations.source_identity(entry),
      message_keys: quoted.keys,
      conversation_refs: quoted.conversations,
      transport: entry.destination_transport,
      conversation_ref: entry.destination_conversation_ref,
      thread_ref: entry.destination_thread_ref,
      repository_ref: entry.repository_ref,
      execution_mode: entry.execution_mode,
      policy: attempt.policy,
      policy_digest: attempt.policy_digest,
      execution_target: attempt.execution_target,
      decided_at: decided_at(attempt, entry),
      inserted_at: now,
      updated_at: now
    }

    if forgotten?(identity, quoted) do
      %{identity | forgotten_at: now}
    else
      %{
        identity
        | prompt: redacted_text(prompt, document, secrets),
          output_schema: attempt.submission["output_schema"],
          answer: redacted_answer(attempt.response["assistant_message"], secrets),
          rejected_answers: rejected_answers(attempt, secrets),
          decision: decision(entry),
          outcome: outcome(entry, episode),
          usage: usage(attempt, identity.decided_at)
      }
    end
  end

  # When routing committed the decision, as the attempt recorded it.
  defp decided_at(%Admission.Attempt{milestones: %{"committed" => at}}, entry)
       when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, decided_at, _offset} ->
        UTCDateTime.to_usec(decided_at)

      {:error, _reason} ->
        entry.updated_at
    end
  end

  defp decided_at(_attempt, entry), do: entry.updated_at

  # -- What the prompt quotes ----------------------------------------------------

  @doc """
  The key an example's `message_keys` holds for one quoted message: its
  conversation and its reference there, as the observation learning keeps of
  it names them (`source_message_ref`).
  """
  @spec message_key(String.t(), String.t()) :: String.t()
  def message_key(conversation_ref, message_ref)
      when is_binary(conversation_ref) and is_binary(message_ref) do
    CanonicalJSON.digest(%{
      "conversation_ref" => conversation_ref,
      "message_ref" => message_ref
    })
  end

  # The key an example's `message_keys` holds for one quoted learned topic.
  defp knowledge_key(knowledge_id) when is_binary(knowledge_id),
    do: CanonicalJSON.digest(%{"knowledge" => knowledge_id})

  @doc """
  Internal — what a routing prompt for `entry` quotes, as its example records
  it: the message and topic keys, and the conversations they come from. The
  improvement candidates that quote the same prompt record the same keys
  (`Ryker.Improvement.Evidence`), as do the local routing comparisons of it
  (`Ryker.LocalRouting`).
  """
  @spec quoted_keys(Ingress.Inbox.Entry.t()) :: %{keys: [String.t()], conversations: [String.t()]}
  def quoted_keys(%Ingress.Inbox.Entry{} = entry),
    do: entry |> quoted() |> Map.take([:keys, :conversations])

  # The message itself; the thread root, the earlier messages and the current
  # one of its conversation; learned observations, with the conversation each
  # came from; the messages the candidates' previews quote, wherever they were
  # sent; and learned topics. The prompt names them by their words alone, so
  # they are read from the context routing froze beside it, which keeps each
  # one's reference until the message's bodies are pruned.
  defp quoted(entry) do
    context = if is_map(entry.admission_context), do: entry.admission_context, else: %{}

    messages =
      [own_message(entry)] ++
        history_messages(entry.destination_conversation_ref, context) ++
        observed_messages(context) ++ previewed_messages(context)

    topics =
      for %{"source_ref" => "knowledge:" <> id} = topic <- list(context["conversation_knowledge"]),
          do: {id, topic["conversation_ref"]}

    %{
      messages: Enum.uniq(messages),
      topics: Enum.map(topics, &elem(&1, 0)) |> Enum.uniq(),
      keys:
        (Enum.map(messages, fn {conversation_ref, message_ref} ->
           message_key(conversation_ref, message_ref)
         end) ++
           Enum.map(topics, &knowledge_key(elem(&1, 0))))
        |> Enum.uniq()
        |> Enum.sort(),
      conversations:
        (Enum.map(messages, &elem(&1, 0)) ++
           for(
             {_id, conversation_ref} when is_binary(conversation_ref) <- topics,
             do: conversation_ref
           ))
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp history_messages(conversation, context) do
    history =
      if is_map(context["conversation_context"]), do: context["conversation_context"], else: %{}

    for %{"source_message_ref" => ref} when is_binary(ref) <-
          [history["root"], history["current"] | list(history["messages"])],
        do: {conversation, ref}
  end

  defp observed_messages(context) do
    for %{"conversation_ref" => observed_in, "source_message_ref" => ref}
        when is_binary(observed_in) and is_binary(ref) <-
          list(context["conversation_observations"]),
        do: {observed_in, ref}
  end

  defp previewed_messages(context) do
    for %{"conversation_ref" => previewed_in, "message_ref" => ref}
        when is_binary(previewed_in) and is_binary(ref) <- list(context["candidate_messages"]),
        do: {previewed_in, ref}
  end

  defp list(values) when is_list(values), do: values
  defp list(_absent), do: []

  # A message as a key names it: its conversation, and its reference there.
  defp own_message(entry),
    do: {entry.destination_conversation_ref, entry.source_item_ref || entry.native_input_id}

  @doc """
  Internal — whether a person already forgot, deleted or edited anything a
  routing prompt for `entry` quotes, by the same test a copy passes before it
  keeps one. The analysis of a request people were unhappy with reads a
  routing attempt's own prompt only when this says no
  (`Ryker.Improvement.Evidence`), and the local routing model is sent one
  only then (`Ryker.LocalRouting`).
  """
  @spec quotes_forgotten?(Ingress.Inbox.Entry.t()) :: boolean()
  def quotes_forgotten?(%Ingress.Inbox.Entry{} = entry) do
    quoted = quoted(entry)

    forgotten?(
      %{source_identity: Learning.Observations.source_identity(entry), message_keys: quoted.keys},
      quoted
    )
  end

  # Whether a person already removed anything the prompt quotes: the message
  # or one it quotes forgotten, deleted or its words edited, a topic
  # forgotten, or a Slack channel it came from deleted.
  defp forgotten?(example, quoted) do
    example.source_identity
    |> Learning.ConversationObservation.Query.by_identity()
    |> Learning.ConversationObservation.Query.forgotten()
    |> Repo.exists?() or
      forgotten_message?(quoted.messages) or
      deleted_message?(quoted.messages) or
      edited_messages(quoted.messages) != [] or
      forgotten_topic?(quoted.topics) or
      deleted_channel?(quoted.conversations)
  end

  defp forgotten_topic?(ids) do
    ids = for id <- ids, {:ok, id} <- [Ecto.UUID.cast(id)], do: id

    ids != [] and
      ids
      |> Knowledge.ConversationKnowledge.Query.by_ids()
      |> Knowledge.ConversationKnowledge.Query.forgotten()
      |> Repo.exists?()
  end

  # Whether a quoted message was forgotten or deleted, asked of those messages
  # alone: each check read every forgotten note and every deletion of each
  # quoted conversation, on every copy and every prompt sent to the local
  # model (2026-10-04 review).
  defp forgotten_message?([]), do: false

  defp forgotten_message?(messages) do
    messages
    |> Learning.ConversationObservation.Query.by_messages()
    |> Learning.ConversationObservation.Query.forgotten()
    |> Repo.exists?()
  end

  defp deleted_message?([]), do: false

  defp deleted_message?(messages),
    do: messages |> Ingress.Inbox.Entry.Query.deletions_of() |> Repo.exists?()

  # The messages among these whose words a person replaced by editing them.
  # A routing prompt quotes the revision it read, and a later prompt quotes
  # every revision of the conversation, the replaced ones with the rest, so
  # a message whose words were edited counts as taken back whichever
  # revision a prompt quoted.
  defp edited_messages(messages) do
    for {message, history} <- edit_histories(messages),
        replaced_words?(history),
        do: message
  end

  @doc """
  Internal — the ids of the revisions among `entries`' messages whose words a
  person replaced by editing them: each one before the message's latest edit
  by a person that says something else. The analysis of a request people
  were unhappy with leaves their words out, as it does a deleted message's
  (`Ryker.Improvement.Evidence`).
  """
  @spec edited_revisions([Ingress.Inbox.Entry.t()]) :: MapSet.t(Ecto.UUID.t())
  def edited_revisions(entries) when is_list(entries) do
    entries
    |> Enum.map(&own_message/1)
    |> Enum.uniq()
    |> edit_histories()
    |> Enum.flat_map(fn {_message, history} ->
      replaced(history, history |> Enum.filter(&person_edit?/1) |> List.last())
    end)
    |> MapSet.new()
  end

  defp replaced(_history, nil), do: []

  defp replaced(history, latest) do
    for revision <- history,
        revision.revision < latest.revision and not same_words?(revision, latest),
        do: revision.id
  end

  # An edit replaced the words when a person made it and the revision before
  # it said something else, or Ryker no longer holds what it said. Only the
  # text a person wrote counts: Slack reports a link's preview arriving as an
  # edit with the text untouched, and taking that for an edit would take back
  # nearly every prompt, each quoting a channel's last twenty messages. An app
  # updating its own message, as an alert does when it resolves, takes nothing
  # back either.
  defp replaced_words?(history) do
    [nil | history]
    |> Enum.zip(history)
    |> Enum.any?(fn {before, revision} ->
      person_edit?(revision) and (is_nil(before) or not same_words?(before, revision))
    end)
  end

  defp person_edit?(revision), do: revision.event_kind == :edit and revision.actor_kind == :user

  # Text that cannot be read, pruned or never text at all, such as a GitHub
  # comment's, is never the same: forgetting then errs toward erasing.
  defp same_words?(%{text: text}, %{text: text}) when is_binary(text), do: true
  defp same_words?(_revision, _other), do: false

  # Every revision, oldest first, of each of these messages that has an edit,
  # by the message as a key names it. An edit is found by its own index, and
  # the revisions before it by the message's source.
  defp edit_histories([]), do: %{}

  defp edit_histories(messages) do
    conversations = messages |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    refs = messages |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    wanted = MapSet.new(messages)

    conversations
    |> Ingress.Inbox.Entry.Query.edit_histories(refs)
    |> Repo.all()
    |> Enum.filter(&MapSet.member?(wanted, &1.message))
    |> Enum.group_by(& &1.message)
    |> Map.new(fn {message, history} ->
      {message, Enum.sort_by(history, &{&1.revision, &1.inserted_at})}
    end)
  end

  defp deleted_channel?(conversations) do
    channels =
      for conversation <- conversations,
          {:ok, workspace, channel} <- [ConversationRef.parse_slack(conversation)],
          do: {workspace, channel}

    workspaces = channels |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    channels != [] and
      workspaces
      |> Slack.ChannelMembership.Query.deleted_in_workspaces()
      |> Repo.all()
      |> Enum.any?(&(&1 in channels))
  end

  # -- Redaction -------------------------------------------------------------------

  defp decoded(text) do
    case Jason.decode(text) do
      {:ok, document} when is_map(document) or is_list(document) -> document
      _text -> nil
    end
  end

  # The exact bytes routing sent, unless redaction removed something; then the
  # redacted document encoded the way the original was, when either encoder
  # reproduces it, so a redacted prompt differs only where a secret was.
  defp redacted_text(text, nil, secrets), do: InspectionRedactor.redact(text, secrets)

  defp redacted_text(text, document, secrets) do
    case InspectionRedactor.redact(document, secrets) do
      ^document -> text
      redacted -> encoder(text, document).(redacted)
    end
  end

  defp redacted_answer(answer, secrets), do: redacted_text(answer, decoded(answer), secrets)

  # The answers routing refused before the one it accepted, oldest first,
  # redacted as that one is, each with the code of why and the correction the
  # model was sent (`Ryker.Admission.Attempts.reject/3`).
  defp rejected_answers(%Admission.Attempt{rejections: rejections}, secrets)
       when is_list(rejections) do
    for %{"answer" => answer, "reason" => reason} = rejection <- rejections,
        is_binary(answer) and is_binary(reason) do
      %{
        "answer" => redacted_answer(answer, secrets),
        "reason" => reason,
        "correction" =>
          rejection["correction"] && InspectionRedactor.redact(rejection["correction"], secrets)
      }
    end
  end

  defp rejected_answers(_attempt, _secrets), do: []

  defp encoder(text, %{"instructions" => instructions, "context" => context} = document)
       when is_binary(instructions) and is_map(context) do
    if Admission.Prompt.render(document) == text,
      do: &Admission.Prompt.render/1,
      else: &CanonicalJSON.encode!/1
  end

  defp encoder(_text, _document), do: &CanonicalJSON.encode!/1

  # -- Labels ----------------------------------------------------------------------

  # What routing decided, without its words: those are in the answer.
  defp decision(entry) do
    document = if is_map(entry.decision_document), do: entry.decision_document, else: %{}

    %{
      "action" => Atom.to_string(entry.decision_action),
      "work_class" => document["work_class"],
      "relation" => document["relation"],
      "repository" => document["repository"],
      "reactions" => reactions(document["reactions"]),
      "messages" => length(list(document["messages"]))
    }
  end

  defp reactions(reactions) when is_list(reactions) do
    Enum.map(reactions, fn
      %{"emoji_name" => name} -> name
      name -> name
    end)
  end

  defp reactions(_none), do: []

  # What happened after: the request's state and its last Work turn when the
  # decision started or joined one, and how routing's own replies and
  # reactions went when it sent any.
  defp outcome(entry, episode) do
    turn =
      episode &&
        episode.id
        |> Work.Turn.Query.by_episode_id()
        |> Work.Turn.Query.ordered_by_recent()
        |> Work.Turn.Query.limit_to(1)
        |> Work.Turn.Query.select_statuses()
        |> Repo.one()

    sent =
      entry.id
      |> Delivery.RoutingResponse.Query.by_input_id()
      |> Delivery.RoutingResponse.Query.count_by_status()
      |> Repo.all()

    %{
      "request" => episode && Atom.to_string(episode.state),
      "turn" => turn && Atom.to_string(turn),
      "sent" =>
        if(sent == [],
          do: nil,
          else: Map.new(sent, fn {status, count} -> {Atom.to_string(status), count} end)
        )
    }
  end

  # What the attempt measured, as `TrainingExamples.usage/5` labels it.
  defp usage(attempt, decided_at) do
    measured = if is_map(attempt.measurements), do: attempt.measurements, else: %{}

    tokens =
      if measured["usage_recorded"] == true do
        Map.new(~w(input cached_input output reasoning), fn kind ->
          {kind <> "_tokens", measured["usage_#{kind}_tokens"]}
        end)
      end

    cost = if measured["usage_cost_recorded"] == true, do: measured["usage_cost_usd"]

    TrainingExamples.usage(tokens, cost, attempt.execution_target, decided_at, %{
      "provider_ms" => measured["usage_provider_ms"],
      "queued_ms" => measured["usage_queued_ms"]
    })
  end

  # -- Forgetting ------------------------------------------------------------------

  @doc """
  Erases the examples that quote any of these observed messages, inside the
  transaction that forgets them.
  """
  @spec forget_messages_in_transaction([Learning.ConversationObservation.t()]) :: :ok
  def forget_messages_in_transaction([]), do: :ok

  def forget_messages_in_transaction(observations) do
    :ok =
      observations
      |> Enum.map(&{&1.conversation_ref, &1.source_message_ref})
      |> Learning.forget_messages_in_transaction()

    erase_in_transaction(
      Enum.map(observations, & &1.identity_key),
      Enum.map(observations, &message_key(&1.conversation_ref, &1.source_message_ref))
    )
  end

  @doc "Erases the examples that quote any of these learned topics, inside the transaction that forgets them."
  @spec forget_topics_in_transaction([Ecto.UUID.t()]) :: :ok
  def forget_topics_in_transaction([]), do: :ok

  def forget_topics_in_transaction(ids) do
    :ok = Learning.forget_topics_in_transaction(ids)
    erase_in_transaction([], Enum.map(ids, &knowledge_key/1))
  end

  @doc """
  Whether recording `entry` takes back what its message said: a deletion
  does, and a person's edit does when its text differs from the revision
  before it. An edit that leaves the text as it was, as Slack reports a
  link's preview arriving, takes nothing back, and neither does an app or a
  bot updating its own message.
  """
  @spec takes_back_words?(Ingress.Inbox.Entry.t()) :: boolean()
  def takes_back_words?(%Ingress.Inbox.Entry{event_kind: :delete}), do: true

  def takes_back_words?(%Ingress.Inbox.Entry{event_kind: :edit, actor_kind: :user} = entry),
    do: edited_messages([own_message(entry)]) != []

  def takes_back_words?(%Ingress.Inbox.Entry{}), do: false

  @doc """
  Erases the examples that quote a message somebody took back
  (`takes_back_words?/1`), inside the transaction that records it (`entry`
  is that revision).
  """
  @spec forget_message_in_transaction(Ingress.Inbox.Entry.t()) :: :ok
  def forget_message_in_transaction(%Ingress.Inbox.Entry{} = entry) do
    {conversation, message} = own_message(entry)
    :ok = Learning.forget_messages_in_transaction([{conversation, message}])

    erase_in_transaction(
      [Learning.Observations.source_identity(entry)],
      [message_key(conversation, message)]
    )
  end

  @doc """
  Erases the examples from a conversation that was deleted, or that quote
  it, inside the transaction that removes what Ryker kept of it.
  """
  @spec forget_conversation_in_transaction(String.t()) :: :ok
  def forget_conversation_in_transaction(conversation_ref) when is_binary(conversation_ref) do
    :ok = lock(:exclusive)
    :ok = Improvement.forget_conversation_in_transaction(conversation_ref)
    :ok = Learning.forget_conversation_in_transaction(conversation_ref)
    :ok = LocalRouting.forget_conversation_in_transaction(conversation_ref)
    :ok = WorkExamples.forget_conversation_in_transaction(conversation_ref)

    conversation_ref |> Example.Query.by_conversation() |> erase()
  end

  defp erase_in_transaction(identities, keys) do
    :ok = lock(:exclusive)
    :ok = Improvement.forget_in_transaction(keys)
    :ok = LocalRouting.forget_in_transaction(identities, keys)
    :ok = WorkExamples.forget_in_transaction(identities, keys)

    identities |> Example.Query.from_sources_or_messages(keys) |> erase()
  end

  defp erase(query) do
    TrainingExamples.erase(Feedback.Query.by_examples(query), Example.Query.kept(query), @bodies)
  end

  @doc """
  Holds, until the transaction ends, the lock a copy holds (shared, where
  every forgetting holds it exclusively), for anything else that copies what
  a person may forget: the evidence an analysis prompt or an accepted case
  freezes (`Ryker.Improvement`), the prompt the local routing model is
  sent (`Ryker.LocalRouting`), and each work example (`Ryker.WorkExamples`). Take it before reading what is copied, and
  before locking any row a forgetting writes only once it holds the lock,
  such as a candidate: a forgetting then either committed before the read,
  or waits and finds what the copy saved.
  """
  @spec copy_lock_in_transaction() :: :ok
  def copy_lock_in_transaction, do: lock(:shared)

  defp lock(mode), do: AdvisoryLock.hold!(@lock, mode)
end
