defmodule Ryker.RoutingExamples do
  @moduledoc """
  Routing decisions kept for training a smaller routing model.

  While a person keeps "Keep routing examples for training" on (Settings ›
  Data retention), each routing decision is copied once it has settled:
  routing committed it and nothing it started is still running. The Work it
  started or joined has come to rest (`Ryker.Work.Custody.work_rest_query/0`,
  the rest Learning waits for), and each quick reply or reaction it chose was
  delivered or gave up. Its outcome is known then, and its bodies are still
  there: they are pruned only after that Work's sessions are discarded.

  The copy holds the exact prompt routing sent and the model's answer, both
  redacted (`Ryker.InspectionRedactor.redact/2`, with every stored credential
  among the values it removes), the decision and what happened next as
  labels, and the tokens and cost. It names the message and the request it
  came from without a foreign key, so the operational, history and audit
  horizons never reach it; only its own window does (`Ryker.Retention.Data`).

  A person forgetting wins. Forgetting a fact or a learned topic, deleting a
  message in Slack, or deleting a Slack channel erases every example whose
  prompt quoted that message, topic or conversation, in the same transaction,
  what improvement candidates hold about it (`Ryker.Improvement`), and the
  local routing comparisons still waiting to send such a prompt
  (`Ryker.LocalRouting`). An erased example keeps only its identity, so it is
  never copied again.
  One whose message was forgotten before its turn to be copied is checked at
  the copy, which then records only that identity. Each copy and each
  forgetting holds one lock (shared by copies, exclusive to forgetting), so
  a copy in flight can never slip past a forgetting that is committing.

  What the prompt quotes and forgetting can reach: the message itself, the
  earlier messages of its thread or channel, learned observations and topics.
  The previews of earlier requests offered as candidates carry no message
  identity, so they are the one quotation forgetting cannot trace.
  """

  import Ecto.Query

  require Logger

  alias Ryker.Accounting.Pricing
  alias Ryker.Admission.{Attempt, Prompt}
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Episodes.Episode
  alias Ryker.Improvement
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Learning.{ConversationObservation, Observations}
  alias Ryker.LocalRouting
  alias Ryker.Repo
  alias Ryker.RoutingExamples.Example
  alias Ryker.Settings.Retention
  alias Ryker.Slack.ChannelMembership
  alias Ryker.Work.{Custody, Turn}

  @lock "ryker-routing-examples"

  @type capture_result :: %{copied: non_neg_integer(), forgotten: non_neg_integer()}

  # -- Copying -------------------------------------------------------------------

  @doc """
  Copies up to `batch_size` settled routing decisions decided within
  `window_seconds` that have no example yet, redacting `redaction_secrets`
  beside the values `Ryker.InspectionRedactor.configured_secrets/0` names.

  `copied` counts the examples kept and `forgotten` those taken as identity
  only, because a message they quote was forgotten first. Nothing is copied
  while keeping routing examples is off.
  """
  @spec capture(map()) :: {:ok, capture_result()}
  def capture(%{batch_size: batch_size, window_seconds: window_seconds} = options)
      when is_integer(batch_size) and batch_size > 0 and is_integer(window_seconds) and
             window_seconds > 0 do
    secrets = secrets(Map.get(options, :redaction_secrets, []))

    results =
      batch_size
      |> settled_inputs(window_seconds)
      |> Enum.map(&copy(&1, secrets))

    {:ok,
     %{
       copied: Enum.count(results, &(&1 == {:ok, :copied})),
       forgotten: Enum.count(results, &(&1 == {:ok, :forgotten}))
     }}
  end

  # A decided message whose routing turn completed and was committed, whose
  # bodies are still kept, with no example yet, and with nothing it started
  # still running. Taken oldest first.
  defp settled_inputs(limit, window_seconds) do
    Repo.all(
      from(input in Entry,
        as: :input,
        join: attempt in Attempt,
        on: attempt.input_id == input.id and attempt.generation == input.execution_generation,
        where: input.status == :decided and is_nil(input.operational_pruned_at),
        where:
          fragment(
            "? > clock_timestamp() - (? * interval '1 second')",
            input.updated_at,
            ^window_seconds
          ),
        where: attempt.phase == "committed" and is_nil(attempt.operational_pruned_at),
        where: fragment("(?::jsonb)->>'state' = 'completed'", attempt.response),
        where: fragment("(?::jsonb)->>'assistant_message' IS NOT NULL", attempt.response),
        where: fragment("(?::jsonb)->>'prompt' IS NOT NULL", attempt.submission),
        where: fragment("(?::jsonb)->'output_schema' IS NOT NULL", attempt.submission),
        where:
          not exists(from(example in Example, where: example.input_id == parent_as(:input).id)),
        where:
          not exists(
            from(work in subquery(Custody.work_rest_query()),
              where: work.episode_id == parent_as(:input).episode_id and work.running
            )
          ),
        where:
          not exists(
            from(response in RoutingResponse,
              where: response.input_id == parent_as(:input).id and response.status == :pending
            )
          ),
        order_by: [asc: input.updated_at, asc: input.id],
        limit: ^limit,
        select: input.id
      )
    )
  end

  # One decision that cannot be copied is logged and left for the next pass,
  # never allowed to stop the copy of every decision after it; only losing the
  # database stops a pass, for the worker's backoff.
  defp copy(input_id, secrets) do
    copy_in_transaction(input_id, secrets)
  rescue
    error in DBConnection.ConnectionError ->
      reraise error, __STACKTRACE__

    error ->
      # The exception can carry the prompt, so only its kind is logged.
      Logger.error(
        "routing example copy failed input=#{input_id} category=#{inspect(error.__struct__)}"
      )

      {:ok, :skipped}
  end

  defp copy_in_transaction(input_id, secrets) do
    Repo.transaction(fn ->
      # The message is held first and the lock second, the order a deletion
      # recording its revision takes them in, so the two cannot wait on each
      # other.
      with true <- enabled?(),
           %Entry{} = entry <- held_input(input_id),
           %Attempt{} = attempt <- committed_attempt(entry),
           :ok <- lock(:shared),
           false <- Repo.exists?(from(example in Example, where: example.input_id == ^input_id)) do
        entry |> example(attempt, secrets) |> insert!()
      else
        _nothing_to_copy -> :skipped
      end
    end)
  end

  defp enabled? do
    Repo.one(
      from(retention in Retention, select: retention.routing_examples_enabled, lock: "FOR SHARE")
    ) == true
  end

  defp held_input(input_id) do
    Repo.one(
      from(input in Entry,
        where:
          input.id == ^input_id and input.status == :decided and
            is_nil(input.operational_pruned_at),
        lock: "FOR SHARE"
      )
    )
  end

  defp committed_attempt(entry) do
    Repo.one(
      from(attempt in Attempt,
        where:
          attempt.input_id == ^entry.id and attempt.generation == ^entry.execution_generation and
            attempt.phase == "committed" and is_nil(attempt.operational_pruned_at)
      )
    )
  end

  defp insert!(%{forgotten_at: nil} = example) do
    Repo.insert!(example, on_conflict: :nothing, conflict_target: [:input_id])
    :copied
  end

  defp insert!(example) do
    Repo.insert!(example, on_conflict: :nothing, conflict_target: [:input_id])
    :forgotten
  end

  defp example(entry, attempt, secrets) do
    now = Repo.now!()
    prompt = attempt.submission["prompt"]
    document = decoded(prompt)
    quoted = quoted(entry)
    episode = entry.episode_id && Repo.get(Episode, entry.episode_id)

    identity = %Example{
      id: Ecto.UUID.generate(),
      input_id: entry.id,
      episode_id: entry.episode_id,
      episode_ref: episode && episode.key,
      source_identity: Observations.source_identity(entry),
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
          decision: decision(entry),
          outcome: outcome(entry, episode),
          usage: usage(attempt, identity.decided_at)
      }
    end
  end

  # When routing committed the decision, as the attempt recorded it.
  defp decided_at(%Attempt{milestones: %{"committed" => at}}, entry) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, %DateTime{microsecond: {microsecond, _precision}} = decided_at, _offset} ->
        %{decided_at | microsecond: {microsecond, 6}}

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
      when is_binary(conversation_ref) and is_binary(message_ref),
      do:
        CanonicalJSON.digest(%{
          "conversation_ref" => conversation_ref,
          "message_ref" => message_ref
        })

  @doc "The key an example's `message_keys` holds for one quoted learned topic."
  @spec knowledge_key(String.t()) :: String.t()
  def knowledge_key(knowledge_id) when is_binary(knowledge_id),
    do: CanonicalJSON.digest(%{"knowledge" => knowledge_id})

  @doc false
  # What a routing prompt for `entry` quotes, as its example records it: the
  # message and topic keys, and the conversations they come from. The
  # improvement candidates that quote the same prompt record the same keys
  # (`Ryker.Improvement`), and forgetting finds the local routing comparisons
  # waiting to send it by them (`Ryker.LocalRouting`).
  @spec quoted_keys(Entry.t()) :: %{keys: [String.t()], conversations: [String.t()]}
  def quoted_keys(%Entry{} = entry), do: entry |> quoted() |> Map.take([:keys, :conversations])

  # The message itself; the thread root, the earlier messages and the current
  # one of its conversation; learned observations, with the conversation each
  # came from; and learned topics. The prompt names them by their words
  # alone, so they are read from the context routing froze beside it, which
  # keeps each one's reference until the message's bodies are pruned.
  defp quoted(entry) do
    conversation = entry.destination_conversation_ref
    context = if is_map(entry.admission_context), do: entry.admission_context, else: %{}

    history =
      if is_map(context["conversation_context"]), do: context["conversation_context"], else: %{}

    messages =
      [{conversation, entry.source_item_ref || entry.native_input_id}] ++
        for(
          %{"source_message_ref" => ref} when is_binary(ref) <-
            [history["root"], history["current"] | list(history["messages"])],
          do: {conversation, ref}
        ) ++
        for(
          %{"conversation_ref" => observed_in, "source_message_ref" => ref}
          when is_binary(observed_in) and is_binary(ref) <-
            list(context["conversation_observations"]),
          do: {observed_in, ref}
        )

    topics =
      for %{"source_ref" => "knowledge:" <> id} = topic <- list(context["conversation_knowledge"]),
          do: {id, topic["conversation_ref"]}

    %{
      messages: Enum.uniq(messages),
      topics: Enum.map(topics, &elem(&1, 0)) |> Enum.uniq(),
      keys:
        (Enum.map(messages, fn {c, m} -> message_key(c, m) end) ++
           Enum.map(topics, &knowledge_key(elem(&1, 0))))
        |> Enum.uniq()
        |> Enum.sort(),
      conversations:
        (Enum.map(messages, &elem(&1, 0)) ++
           for({_id, c} when is_binary(c) <- topics, do: c))
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp list(values) when is_list(values), do: values
  defp list(_absent), do: []

  @doc false
  # Whether a person already forgot or deleted anything a routing prompt for
  # `entry` quotes, by the same test a copy passes before it keeps one. The
  # analysis of a request people were unhappy with reads a routing attempt's
  # own prompt only when this says no (`Ryker.Improvement.Evidence`), and the
  # local routing model is sent one only then (`Ryker.LocalRouting`).
  @spec quotes_forgotten?(Entry.t()) :: boolean()
  def quotes_forgotten?(%Entry{} = entry) do
    quoted = quoted(entry)

    forgotten?(
      %{source_identity: Observations.source_identity(entry), message_keys: quoted.keys},
      quoted
    )
  end

  # Whether a person already removed anything the prompt quotes: the message
  # or one it quotes forgotten or deleted, a topic forgotten, or a Slack
  # channel it came from deleted.
  defp forgotten?(example, quoted) do
    keys = MapSet.new(example.message_keys)

    Repo.exists?(
      from(observation in ConversationObservation,
        where:
          observation.identity_key == ^example.source_identity and
            not is_nil(observation.forgotten_at)
      )
    ) or
      forgotten_messages(quoted.conversations) |> Enum.any?(&MapSet.member?(keys, &1)) or
      deleted_messages(quoted.conversations) |> Enum.any?(&MapSet.member?(keys, &1)) or
      forgotten_topic?(quoted.topics) or
      deleted_channel?(quoted.conversations)
  end

  defp forgotten_topic?(ids) do
    ids = for id <- ids, {:ok, id} <- [Ecto.UUID.cast(id)], do: id

    ids != [] and
      Repo.exists?(
        from(topic in ConversationKnowledge,
          where: topic.id in ^ids and not is_nil(topic.forgotten_at)
        )
      )
  end

  defp forgotten_messages(conversations) do
    Repo.all(
      from(observation in ConversationObservation,
        where:
          observation.conversation_ref in ^conversations and
            not is_nil(observation.forgotten_at),
        select: {observation.conversation_ref, observation.source_message_ref}
      )
    )
    |> Enum.map(fn {c, m} -> message_key(c, m) end)
  end

  defp deleted_messages(conversations) do
    Repo.all(
      from(input in Entry,
        where:
          input.event_kind == :delete and input.destination_conversation_ref in ^conversations,
        select:
          {input.destination_conversation_ref,
           fragment("COALESCE(?, ?)", input.source_item_ref, input.native_input_id)}
      )
    )
    |> Enum.map(fn {c, m} -> message_key(c, m) end)
  end

  # A Slack conversation is "slack:<workspace>:<channel>", as the channel
  # fence reads it (`Ryker.Slack.ChannelFence`).
  defp deleted_channel?(conversations) do
    channels =
      for "slack:" <> rest <- conversations,
          [workspace, channel] <- [String.split(rest, ":", parts: 2)],
          do: {workspace, channel}

    workspaces = channels |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    channels != [] and
      Repo.all(
        from(membership in ChannelMembership,
          where: membership.workspace_ref in ^workspaces and membership.status == :deleted,
          select: {membership.workspace_ref, membership.channel_ref}
        )
      )
      |> Enum.any?(&(&1 in channels))
  end

  # -- Redaction -------------------------------------------------------------------

  defp secrets(stored) do
    (InspectionRedactor.configured_secrets() ++ Enum.filter(stored, &(byte_size(&1) >= 8)))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

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

  defp encoder(text, %{"instructions" => instructions, "context" => context} = document)
       when is_binary(instructions) and is_map(context) do
    if Prompt.render(document) == text, do: &Prompt.render/1, else: &CanonicalJSON.encode!/1
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

  defp reactions(reactions) when is_list(reactions),
    do:
      Enum.map(reactions, fn
        %{"emoji_name" => name} -> name
        name -> name
      end)

  defp reactions(_none), do: []

  # What happened after: the request's state and its last Work turn when the
  # decision started or joined one, and how routing's own replies and
  # reactions went when it sent any.
  defp outcome(entry, episode) do
    turn =
      episode &&
        Repo.one(
          from(turn in Turn,
            where: turn.episode_id == ^episode.id,
            order_by: [desc: turn.inserted_at, desc: turn.id],
            limit: 1,
            select: turn.status
          )
        )

    sent =
      Repo.all(
        from(response in RoutingResponse,
          where: response.input_id == ^entry.id,
          group_by: response.status,
          select: {response.status, count(response.id)}
        )
      )

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

  # The provider's cost when it reported one; otherwise an estimate at the
  # price saved for the model on the day of the decision, as Usage shows it.
  defp usage(attempt, decided_at) do
    measured = if is_map(attempt.measurements), do: attempt.measurements, else: %{}
    recorded = measured["usage_recorded"] == true

    tokens =
      Map.new(~w(input cached_input output reasoning), fn kind ->
        {kind <> "_tokens", if(recorded, do: measured["usage_#{kind}_tokens"])}
      end)

    cost = if measured["usage_cost_recorded"] == true, do: measured["usage_cost_usd"]
    estimated = if recorded and is_nil(cost), do: estimate(attempt, tokens, decided_at)

    Map.merge(tokens, %{
      "cost_usd" => cost,
      "estimated_cost_usd" => estimated,
      "provider_ms" => measured["usage_provider_ms"],
      "queued_ms" => measured["usage_queued_ms"]
    })
  end

  defp estimate(%Attempt{execution_target: target}, tokens, decided_at) when is_binary(target) do
    counts = %{
      input: tokens["input_tokens"],
      cached: tokens["cached_input_tokens"],
      output: tokens["output_tokens"],
      reasoning: tokens["reasoning_tokens"]
    }

    with true <- Enum.all?(Map.values(counts), &(is_integer(&1) or is_nil(&1))),
         %{} = price <- Pricing.in_effect(target, DateTime.to_date(decided_at)) do
      price |> Pricing.estimate(counts) |> Decimal.normalize() |> Decimal.to_string(:normal)
    else
      _unpriced -> nil
    end
  end

  defp estimate(_attempt, _tokens, _decided_at), do: nil

  # -- Forgetting ------------------------------------------------------------------

  @doc """
  Erases the examples that quote any of these observed messages, inside the
  transaction that forgets them.
  """
  @spec forget_messages_in_transaction([ConversationObservation.t()]) :: :ok
  def forget_messages_in_transaction([]), do: :ok

  def forget_messages_in_transaction(observations) do
    erase_in_transaction(
      Enum.map(observations, & &1.identity_key),
      Enum.map(observations, &message_key(&1.conversation_ref, &1.source_message_ref))
    )
  end

  @doc "Erases the examples that quote any of these learned topics, inside the transaction that forgets them."
  @spec forget_topics_in_transaction([Ecto.UUID.t()]) :: :ok
  def forget_topics_in_transaction([]), do: :ok

  def forget_topics_in_transaction(ids),
    do: erase_in_transaction([], Enum.map(ids, &knowledge_key/1))

  @doc """
  Erases the examples that quote a message somebody deleted, inside the
  transaction that records the deletion (`entry` is that revision).
  """
  @spec forget_deleted_in_transaction(Entry.t()) :: :ok
  def forget_deleted_in_transaction(%Entry{event_kind: :delete} = entry) do
    erase_in_transaction(
      [Observations.source_identity(entry)],
      [
        message_key(
          entry.destination_conversation_ref,
          entry.source_item_ref || entry.native_input_id
        )
      ]
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
    :ok = LocalRouting.forget_conversation_in_transaction(conversation_ref)

    erase(
      from(example in Example,
        where:
          example.conversation_ref == ^conversation_ref or
            fragment("? @> ARRAY[?]::text[]", example.conversation_refs, ^conversation_ref)
      )
    )
  end

  defp erase_in_transaction(identities, keys) do
    :ok = lock(:exclusive)
    :ok = Improvement.forget_in_transaction(keys)
    :ok = LocalRouting.forget_in_transaction(identities, keys)

    erase(
      from(example in Example,
        where:
          example.source_identity in ^identities or
            fragment("? && ?::text[]", example.message_keys, ^keys)
      )
    )
  end

  defp erase(query) do
    now = Repo.now!()

    Repo.update_all(
      from(example in query, where: is_nil(example.forgotten_at)),
      set: [
        prompt: nil,
        output_schema: nil,
        answer: nil,
        decision: nil,
        outcome: nil,
        usage: nil,
        forgotten_at: now,
        updated_at: now
      ]
    )

    :ok
  end

  @doc """
  Holds, until the transaction ends, the lock a copy holds (shared, where
  every forgetting holds it exclusively), for anything else that copies what
  a person may forget: the evidence an analysis prompt or an accepted case
  freezes (`Ryker.Improvement`). Take it before reading anything, and before
  any row a forgetting writes, as forgetting takes them: a forgetting then
  either committed before the read, or waits and finds what the copy saved.
  """
  @spec copy_lock_in_transaction() :: :ok
  def copy_lock_in_transaction, do: lock(:shared)

  defp lock(:shared) do
    Repo.query!("SELECT pg_advisory_xact_lock_shared(hashtextextended($1, 0))", [@lock])
    :ok
  end

  defp lock(:exclusive) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [@lock])
    :ok
  end
end
