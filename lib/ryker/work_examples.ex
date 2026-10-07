defmodule Ryker.WorkExamples do
  @moduledoc """
  Work turns kept for training a model that can do Ryker's work later, beside
  the routing decisions `Ryker.RoutingExamples` keeps.

  While a person keeps "Keep work examples for training" on (Settings › Data
  retention), each Work turn is copied once it has settled and the Work it
  belongs to has come to rest (`Ryker.Work.Custody.work_rest_query/0`): its
  result was accepted and delivered, and nothing in its request is still
  running. Its outcome is known then, and its bodies are still there: they
  are pruned only after that Work's sessions are discarded.

  The copy holds the exact prompt the worker was sent with the context and
  schema beside it, what the worker did on the way (its tool calls with their
  input and output, and its progress notes, as `episode_work_activity`
  recorded them), the result Ryker accepted and each one it refused before
  with why, what happened next, and the tokens and cost. The words are
  redacted as routing examples' are (`Ryker.InspectionRedactor.redact/2`,
  with every stored credential among the values it removes). A work example
  carries a customer's code and command output, which a routing example never
  does, so keeping them is a setting of its own. It names the turn and the
  request it came from without a foreign key, so only its own window removes
  it (`Ryker.Retention.Data`); the feedback people give on its request is
  copied beside it as it arrives (`copy_feedback/0`).

  A person forgetting wins, through the same paths and the same lock as
  routing examples: forgetting a fact or a learned topic, deleting or editing
  a message, or deleting a Slack channel erases every work example whose
  request was asked in that message or whose routing quoted it
  (`forget_in_transaction/2`, `forget_conversation_in_transaction/1`, called
  by `Ryker.RoutingExamples` while it holds the lock). An erased example
  keeps only its identity, so it is never copied again, and one whose message
  was forgotten before its turn to be copied is checked at the copy.

  What forgetting can trace is what the request's messages quoted when they
  were routed (`Ryker.RoutingExamples.quoted_keys/1`). A briefing can also
  carry what Work looked up on its own, such as related requests' outcomes,
  and a trajectory what a tool read; a forgotten message only those quote
  stays in the copy until its window ends or keeping work examples is turned
  off.
  """

  require Logger
  alias Ryker.Accounting.Pricing
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.EpisodeQuery
  alias Ryker.Ingress.Inbox.EntryQuery
  alias Ryker.InspectionRedactor
  alias Ryker.Learning.Observations
  alias Ryker.Publication.PublicationQuery
  alias Ryker.Repo
  alias Ryker.RoutingExamples
  alias Ryker.Settings.RetentionQuery
  alias Ryker.Work.{ActivityEventQuery, CandidateResponseQuery, Turn, TurnQuery}
  alias Ryker.WorkExamples.{Example, ExampleQuery, Feedback, FeedbackQuery}

  # What the worker did, as training reads it: a tool call ends in
  # tool.completed with its input and output, so its start adds nothing, and
  # provider liveness says nothing about the work. An elided event marks
  # where the recorder dropped events, so a gap reads as one.
  @trajectory_kinds ~w(tool.completed model.thought model.progress activity.elided)

  @type capture_result :: %{copied: non_neg_integer(), forgotten: non_neg_integer()}

  # -- Copying -------------------------------------------------------------------

  @doc """
  Copies up to `batch_size` settled Work turns settled within
  `window_seconds` that have no example yet, redacting the value of every
  saved credential beside the values `Ryker.InspectionRedactor.configured_secrets/0`
  names.

  `copied` counts the examples kept and `forgotten` those taken as identity
  only, because a message their request was asked in, or one its routing
  quoted, was forgotten first. Nothing is copied while keeping work examples
  is off.
  """
  @spec capture(map()) :: {:ok, capture_result()}
  def capture(%{batch_size: batch_size, window_seconds: window_seconds})
      when is_integer(batch_size) and batch_size > 0 and is_integer(window_seconds) and
             window_seconds > 0 do
    secrets = secrets()

    results =
      batch_size
      |> settled_turns(window_seconds)
      |> Enum.map(&copy(&1, secrets))

    {:ok, _copied} = copy_feedback()

    {:ok,
     %{
       copied: Enum.count(results, &(&1 == {:ok, :copied})),
       forgotten: Enum.count(results, &(&1 == {:ok, :forgotten}))
     }}
  end

  @doc """
  Copies each feedback signal about a kept example's request beside the
  example once (`Ryker.WorkExamples.Feedback`), and returns how many it
  copied. As for routing examples, only the kind, value, category and time
  are copied, under the lock a copy holds.
  """
  @spec copy_feedback() :: {:ok, non_neg_integer()}
  def copy_feedback do
    Repo.transaction(fn ->
      if enabled?() do
        :ok = RoutingExamples.copy_lock_in_transaction()

        {count, _rows} =
          Repo.insert_all(Feedback, FeedbackQuery.copies_of_signals(),
            on_conflict: :nothing,
            conflict_target: [:example_id, :signal_id]
          )

        count
      else
        0
      end
    end)
  end

  # A settled turn whose bodies are still kept, with no example yet, whose
  # request has nothing still running. Taken oldest first.
  defp settled_turns(limit, window_seconds),
    do: limit |> ExampleQuery.settled_turns(window_seconds) |> Repo.all()

  # One turn that cannot be copied is logged and left for the next pass, never
  # allowed to stop the copy of every turn after it; only losing the database
  # stops a pass, for the worker's backoff.
  defp copy(turn_id, secrets) do
    copy_in_transaction(turn_id, secrets)
  rescue
    error in DBConnection.ConnectionError ->
      reraise error, __STACKTRACE__

    error ->
      # The exception can carry the briefing, so only its kind is logged.
      Logger.error(
        "work example copy failed turn=#{turn_id} category=#{inspect(error.__struct__)}"
      )

      {:ok, :skipped}
  end

  defp copy_in_transaction(turn_id, secrets) do
    Repo.transaction(fn ->
      with true <- enabled?(),
           %Turn{} = turn <- held_turn(turn_id),
           :ok <- RoutingExamples.copy_lock_in_transaction(),
           false <- Repo.exists?(ExampleQuery.by_turn_id(turn_id)) do
        turn |> example(secrets) |> insert!()
      else
        _nothing_to_copy -> :skipped
      end
    end)
  end

  defp enabled? do
    enabled =
      RetentionQuery.select_work_examples_enabled()
      |> RetentionQuery.lock_for_share()
      |> Repo.one()

    enabled == true
  end

  defp held_turn(turn_id) do
    turn_id
    |> TurnQuery.by_id()
    |> TurnQuery.settled_with_bodies()
    |> TurnQuery.lock_for_share()
    |> Repo.one()
  end

  defp insert!(%{forgotten_at: nil} = example) do
    Repo.insert!(example, on_conflict: :nothing, conflict_target: [:turn_id])
    :copied
  end

  defp insert!(example) do
    Repo.insert!(example, on_conflict: :nothing, conflict_target: [:turn_id])
    :forgotten
  end

  defp example(turn, secrets) do
    now = Repo.now!()
    episode = Repo.one!(EpisodeQuery.by_id(turn.episode_id))
    inputs = inputs(episode, turn)
    quoted = Enum.map(inputs, &RoutingExamples.quoted_keys/1)
    submission = turn.submission
    context = if is_map(submission["context"]), do: submission["context"], else: %{}

    identity = %Example{
      id: Ecto.UUID.generate(),
      turn_id: turn.id,
      episode_id: episode.id,
      episode_ref: episode.key,
      source_identities: inputs |> Enum.map(&Observations.source_identity/1) |> sorted(),
      message_keys: quoted |> Enum.flat_map(& &1.keys) |> sorted(),
      conversation_refs:
        quoted
        |> Enum.flat_map(& &1.conversations)
        |> Kernel.++(List.wrap(episode.destination_conversation_ref))
        |> sorted(),
      transport: episode.destination_transport,
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: episode.destination_thread_ref,
      repository_ref: if(is_binary(context["repository_ref"]), do: context["repository_ref"]),
      execution_mode: episode.execution_mode,
      execution_target: turn.execution_target,
      settled_at: turn.delivered_at || turn.accepted_at || turn.updated_at,
      inserted_at: now,
      updated_at: now
    }

    if Enum.any?(inputs, &RoutingExamples.quotes_forgotten?/1) do
      %{identity | forgotten_at: now}
    else
      %{
        identity
        | briefing: InspectionRedactor.redact(submission["prompt"] || "", secrets),
          context: InspectionRedactor.redact(context, secrets),
          output_schema: submission["output_schema"] || %{},
          trajectory: trajectory(turn, secrets),
          result: redacted_text(turn.candidate, secrets),
          rejected_results: rejected_results(turn, secrets),
          outcome: outcome(turn, episode),
          usage: usage(turn, identity.settled_at)
      }
    end
  end

  # The messages the request was asked in, up to this turn: every message
  # admitted to it, the earliest first.
  defp inputs(episode, turn),
    do: episode.id |> EntryQuery.admitted_to(turn.inserted_at) |> Repo.all()

  defp sorted(values), do: values |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

  # -- Bodies ----------------------------------------------------------------------

  # What the worker did, oldest first, each event's payload redacted as the
  # briefing is.
  defp trajectory(%Turn{coop_turn_id: coop_turn_id} = turn, secrets)
       when is_binary(coop_turn_id) do
    turn.episode_id
    |> ActivityEventQuery.trajectory(coop_turn_id, @trajectory_kinds)
    |> Repo.all()
    |> Enum.map(fn event ->
      %{
        "kind" => event["kind"],
        "at" => DateTime.to_iso8601(event["at"]),
        "payload" => InspectionRedactor.redact(event["payload"], secrets)
      }
    end)
  end

  defp trajectory(_turn, _secrets), do: []

  # The results Ryker refused before the one it accepted, oldest first, each
  # with the violations it named. The exact body of each attempt is kept
  # apart from the turn (`Ryker.Work.CandidateResponse`); the verdicts are in
  # the turn's validation history.
  defp rejected_results(turn, secrets) do
    verdicts =
      for %{"candidate_attempt" => attempt, "verdict" => "reject"} = verdict <-
            List.wrap(turn.validation_history),
          into: %{},
          do: {attempt, verdict["violations"]}

    turn.id
    |> CandidateResponseQuery.kept_for_turn()
    |> Repo.all()
    |> Enum.filter(&Map.has_key?(verdicts, &1.candidate_attempt))
    |> Enum.map(fn response ->
      %{
        "result" => redacted_text(response.body, secrets),
        "violations" => InspectionRedactor.redact(verdicts[response.candidate_attempt], secrets)
      }
    end)
  end

  # The exact bytes, unless redaction removed something; then the redacted
  # document in canonical JSON, so a redacted result differs only where a
  # secret was.
  defp redacted_text(text, secrets) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, document} when is_map(document) or is_list(document) ->
        case InspectionRedactor.redact(document, secrets) do
          ^document -> text
          redacted -> CanonicalJSON.encode!(redacted)
        end

      _text ->
        InspectionRedactor.redact(text, secrets)
    end
  end

  defp redacted_text(_absent, _secrets), do: ""

  # Every configured secret and the value of every saved credential, read when
  # a batch is copied.
  defp secrets do
    (InspectionRedactor.configured_secrets() ++
       Enum.filter(Ryker.Credentials.redaction_values(), &(byte_size(&1) >= 8)))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  # -- Labels ----------------------------------------------------------------------

  # What happened after: the request's state, the turn's, and how the change it
  # published ended when it published one.
  defp outcome(turn, episode) do
    publication =
      episode.id
      |> PublicationQuery.by_episode_id()
      |> PublicationQuery.newest_first()
      |> PublicationQuery.limit_to(1)
      |> PublicationQuery.select_statuses()
      |> Repo.one()

    %{
      "request" => Atom.to_string(episode.state),
      "turn" => Atom.to_string(turn.status),
      "publication" => publication && Atom.to_string(publication)
    }
  end

  # The provider's cost when it reported one; otherwise an estimate at the
  # price saved for the model on the day the turn settled, as Usage shows it.
  defp usage(turn, settled_at) do
    tokens =
      if turn.usage_recorded do
        %{
          "input_tokens" => turn.usage_input_tokens,
          "cached_input_tokens" => turn.usage_cached_input_tokens,
          "output_tokens" => turn.usage_output_tokens,
          "reasoning_tokens" => turn.usage_reasoning_tokens
        }
      else
        Map.new(~w(input_tokens cached_input_tokens output_tokens reasoning_tokens), &{&1, nil})
      end

    cost =
      if turn.usage_cost_recorded,
        do: turn.usage_cost_usd && Decimal.to_string(turn.usage_cost_usd, :normal)

    estimated = if turn.usage_recorded and is_nil(cost), do: estimate(turn, settled_at)

    Map.merge(tokens, %{
      "cost_usd" => cost,
      "estimated_cost_usd" => estimated,
      "provider_ms" => turn.usage_provider_ms,
      "queued_ms" => turn.usage_queued_ms,
      "host_ms" => turn.usage_host_ms
    })
  end

  defp estimate(%Turn{execution_target: target} = turn, settled_at) when is_binary(target) do
    counts = %{
      input: turn.usage_input_tokens,
      cached: turn.usage_cached_input_tokens,
      output: turn.usage_output_tokens,
      reasoning: turn.usage_reasoning_tokens
    }

    case Pricing.in_effect(target, DateTime.to_date(settled_at)) do
      %{} = price ->
        price |> Pricing.estimate(counts) |> Decimal.normalize() |> Decimal.to_string(:normal)

      _unpriced ->
        nil
    end
  end

  defp estimate(_turn, _settled_at), do: nil

  # -- Forgetting ------------------------------------------------------------------

  @doc false
  # Erases the examples whose request was asked in one of these messages
  # (by source identity) or whose routing quoted one of these keys. Called by
  # `Ryker.RoutingExamples` while it holds the lock exclusively, inside the
  # transaction that forgets them.
  @spec forget_in_transaction([String.t()], [String.t()]) :: :ok
  def forget_in_transaction(identities, keys) do
    identities |> ExampleQuery.from_sources_or_messages(keys) |> erase()
  end

  @doc false
  # Erases the examples from a deleted conversation, or that quote it. Called
  # by `Ryker.RoutingExamples` while it holds the lock exclusively.
  @spec forget_conversation_in_transaction(String.t()) :: :ok
  def forget_conversation_in_transaction(conversation_ref) when is_binary(conversation_ref) do
    conversation_ref |> ExampleQuery.in_conversation() |> erase()
  end

  defp erase(query) do
    now = Repo.now!()

    query |> FeedbackQuery.for_examples() |> Repo.delete_all()

    Repo.update_all(
      ExampleQuery.kept(query),
      set: [
        briefing: nil,
        context: nil,
        output_schema: nil,
        trajectory: nil,
        result: nil,
        rejected_results: nil,
        outcome: nil,
        usage: nil,
        forgotten_at: now,
        updated_at: now
      ]
    )

    :ok
  end
end
