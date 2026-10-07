defmodule Ryker.ControlPlane.LearningRequests do
  @moduledoc """
  Background learning as the Timeline's model-request cards.

  Each learning attempt that read a set of messages becomes a briefing card
  and a result card, like routing and work: what the pass was told, the
  messages and topics it read, the exact prompt and response format, then the
  model's response and reason, what it saved or proposed, what it cost and
  where its time went, and whether Ryker's checks passed. Everything is read
  from the attempt's own frozen record, the execution ledger its worker's
  report was metered into, and the topic revisions its response wrote; nothing
  is rebuilt from today's settings, and retention says what it removed.

  An attempt belongs to the messages its frozen selection names. `paths/1`
  says where each attempt's card is drawn, so the Learning and Learned pages
  open the same card instead of a copy of their own (Andrew, 2026-09-26: the
  Timeline should make the Learning page's own receipt obsolete; it is gone).
  """
  import Ryker.ControlPlane.BackgroundCards,
    only: [
      artifact_options: 2,
      decode: 1,
      identifier: 2,
      present: 1,
      record_text: 2,
      submitted: 5,
      target: 2,
      time: 2,
      timestamp: 1
    ]

  alias Ryker.Accounting.Execution
  alias Ryker.ControlPlane.{BackgroundCards, CallRun, ConversationMemory, LearningActivity}
  alias Ryker.ControlPlane.{LearningRequests, Paths}
  alias Ryker.InspectionRedactor, as: Redactor
  alias Ryker.Learning.LearningRun
  alias Ryker.Repo
  alias Ryker.Slack.Names
  alias Ryker.Work.Session

  @limit 50

  @doc """
  The briefing and result cards of the learning attempts that read any of
  `input_ids`, oldest first, bounded to the latest #{@limit}.

  Options: `:secrets` to redact, `:disclosed` with the artifact ids a reader
  opened (an attempt's prompt text is prepared only then), and `:scope`,
  `:request` or `:message`, for how a card counts the messages that are this
  page's.
  """
  @spec entries([Ecto.UUID.t()], keyword()) :: [map()]
  def entries(input_ids, options \\ [])
  def entries([], _options), do: []

  def entries(input_ids, options) do
    local = MapSet.new(input_ids)

    case runs_for(input_ids, local) do
      [] -> []
      runs -> cards(runs, local, options)
    end
  end

  @doc """
  Where each attempt's card is drawn, by attempt id: the Timeline of the first
  message it read that belongs to a request, else that first message's own
  page, at the attempt's result card, or its briefing while it has no result.
  An attempt whose messages are all gone has no page.
  """
  @spec paths([map()]) :: %{Ecto.UUID.t() => String.t() | nil}
  def paths([]), do: %{}

  def paths(runs) do
    ids = runs |> Enum.flat_map(&read/1) |> Enum.uniq()

    keys = ids |> LearningRequests.Query.message_requests() |> Repo.all() |> Map.new()

    Map.new(runs, fn run ->
      read = read(run)

      # The request the message joined, or the message's own page before any did.
      page =
        Enum.find_value(read, &(keys[&1] && Paths.request(keys[&1]))) ||
          Enum.find_value(read, &(Map.has_key?(keys, &1) && Paths.request(&1)))

      {run.id, page && page <> "#" <> card_id(run)}
    end)
  end

  # The result card stands for an attempt that got an answer or ended; one
  # still waiting on its model has only its briefing.
  defp card_id(run) do
    if result_card?(run), do: "learning-#{run.id}-result", else: "learning-#{run.id}"
  end

  defp result_card?(%{status: :prepared, remote_stopped_at: nil}), do: false
  defp result_card?(_run), do: true

  # The messages an attempt read, in the order its frozen selection lists them.
  defp read(%{inputs: inputs}) do
    for %{"source_input_id" => id} <- List.wrap(inputs), is_binary(id), do: id
  end

  # Attempts reach these messages through the batch that holds them, a
  # relearning batch whose chosen messages name them, or, for an attempt
  # prepared before batches, its own frozen selection. An attempt is shown
  # only when its selection names one of them.
  defp runs_for(input_ids, local) do
    patterns = Enum.map(input_ids, &("%" <> &1 <> "%"))

    batch_ids =
      Repo.all(LearningRequests.Query.batches_holding(input_ids)) ++
        Repo.all(LearningRequests.Query.rebuilds_selecting(patterns))

    batch_ids
    |> Enum.uniq()
    |> LearningRequests.Query.runs_of(patterns, @limit)
    |> Repo.all()
    |> Enum.filter(fn run -> Enum.any?(read(run), &MapSet.member?(local, &1)) end)
    |> Enum.reverse()
  end

  defp cards(runs, local, options) do
    ids = Enum.map(runs, & &1.id)
    secrets = Keyword.get(options, :secrets, [])

    context = %{
      secrets: secrets,
      disclosed: Keyword.get(options, :disclosed),
      scope: Keyword.get(options, :scope, :request),
      local: local,
      runs: Map.new(runs, &{&1.id, &1}),
      numbers: numbers(runs),
      executions:
        "learning"
        |> Execution.Query.by_sources(ids)
        |> Repo.all()
        |> Map.new(&{&1.source_id, &1}),
      sessions:
        ids
        |> Session.Query.by_learning_run_ids()
        |> Repo.all()
        |> Map.new(&{&1.learning_run_id, &1}),
      changes: changes(runs, secrets)
    }

    Enum.flat_map(runs, fn run -> [briefing(run, context) | result(run, context)] end)
  end

  # Attempts are numbered within their batch in the order they began, as the
  # Learning page numbers them; an attempt without a batch keeps its own count.
  defp numbers(runs) do
    batch_ids = runs |> Enum.map(& &1.batch_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    ordered =
      batch_ids
      |> LearningRequests.Query.attempts_in_order()
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    Map.new(runs, fn
      %{batch_id: nil} = run ->
        {run.id, %{number: run.generation, total: nil, previous: nil}}

      run ->
        attempts = Map.get(ordered, run.batch_id, [run.id])
        index = Enum.find_index(attempts, &(&1 == run.id)) || 0

        {run.id,
         %{
           number: index + 1,
           total: length(attempts),
           previous: if(index > 0, do: Enum.at(attempts, index - 1))
         }}
    end)
  end

  # The topic revisions each attempt's exact response wrote.
  defp changes(runs, secrets) do
    refs =
      for %{result_sha256: digest} = run <- runs,
          is_binary(digest),
          into: %{},
          do: {"learning:#{run.id}:#{digest}", run.id}

    if refs == %{} do
      %{}
    else
      refs
      |> Map.keys()
      |> LearningRequests.Query.revisions_written()
      |> Repo.all()
      |> Enum.group_by(&Map.fetch!(refs, &1.source_result_ref), fn revision ->
        %{
          topic: revision.knowledge_id,
          version: revision.version,
          title: present(Redactor.document(revision.state, secrets)["title"])
        }
      end)
    end
  end

  defp briefing(run, context) do
    prompt = decode(run.prompt)
    options = artifact_options(run, context)
    request_id = "learning-#{run.id}-request"

    run
    |> base(context)
    |> Map.merge(%{
      id: "learning-#{run.id}",
      phase: :submission,
      at: run.inserted_at,
      sort_at: run.inserted_at,
      # An attempt still waiting on its model has no result card to carry them.
      identity: if(not result_card?(run), do: identity(run, context)),
      retention_note:
        if run.pruned_at do
          "Retention removed the messages, instructions and prompt this attempt was sent on " <>
            timestamp(run.pruned_at) <> ". Nothing is rebuilt from today's settings."
        end,
      sections: [
        section("instructions", "Learning instructions", prompt["instructions"], options),
        section("context", "What learning was given", briefing_context(prompt), options),
        section("contract", "Required output contract", run.output_schema, options),
        submitted(run.prompt, request_id, :learning, context, options)
      ]
    })
  end

  defp result(run, context) do
    if result_card?(run) do
      options = artifact_options(run, context)
      document = run.result |> decode() |> Redactor.document(context.secrets)
      ended = run.applied_at || run.remote_stopped_at || run.updated_at

      [
        run
        |> base(context)
        |> Map.merge(%{
          id: "learning-#{run.id}-result",
          phase: :result,
          at: ended,
          sort_at: ended,
          run: CallRun.from_background(run, context.executions[run.id]),
          retried_after: retried_after(run, context),
          retention_note:
            if run.pruned_at do
              "Retention removed the model's response on #{timestamp(run.pruned_at)}. " <>
                "What it changed, what it cost and how long it took stay recorded."
            end,
          sections: [section("response", "Model response", run.result, options)],
          background: %{
            headline: LearningActivity.attempt_label(run),
            reason: present(document["reason"]),
            facts: facts(run, document, context)
          },
          identity: identity(run, context)
        })
      ]
    else
      []
    end
  end

  defp base(run, context) do
    number = context.numbers[run.id]

    %{
      kind: :request,
      source_kind: :learning,
      band: :learning,
      # Learning belongs to the request as a whole, never to one message's band.
      owner: :episode,
      # A pass's attempts share their batch: one section on the Timeline.
      occurrence: run.batch_id || run.id,
      title: "Learning",
      target: target(run, context.executions[run.id]) || "Execution target not recorded",
      status: run.status,
      policy: run.policy,
      policy_digest: run.policy_digest,
      generation: number.number,
      generations: number.total,
      counts: %{},
      href: nil,
      # The briefing names Slack people while it is drawn; see `Names.revision/0`.
      names: Names.revision()
    }
  end

  # Everything the model was given beside its instructions: the custom
  # instructions, the messages, the topics it could update and, on a retry,
  # what went wrong before.
  defp briefing_context(prompt) do
    case Map.delete(prompt, "instructions") do
      context when map_size(context) == 0 -> nil
      context -> context
    end
  end

  # A retry says which attempt it followed and why that one ended, as routing
  # does; the reason is the Learning page's own sentence for it.
  defp retried_after(run, context) do
    with %{previous: previous} when is_binary(previous) <- context.numbers[run.id],
         %LearningRun{} = earlier <- context.runs[previous],
         error when is_binary(error) <- LearningActivity.attempt_error(earlier) do
      %{
        generation: context.numbers[previous].number,
        summary: error,
        href: "#" <> card_id(earlier)
      }
    else
      _none -> nil
    end
  end

  # What the attempt did, in the order a reader asks: did it save anything,
  # which topics, what it held back or proposed, and how much of what it read
  # is this page's.
  defp facts(run, document, context) do
    changes = Map.get(context.changes, run.id, [])
    updates = updates(document)

    [outcome(run, updates, changes)]
    |> Kernel.++(Enum.map(changes, &change/1))
    |> Kernel.++(unlinked_saves(run, updates, changes))
    |> Kernel.++(proposals(run, updates))
    |> Kernel.++(deferrals(updates))
    |> Kernel.++([messages(run, context)])
    |> Enum.reject(&is_nil/1)
  end

  defp updates(%{"updates" => updates}) when is_list(updates),
    do: Enum.filter(updates, &is_map/1)

  defp updates(_document), do: nil

  defp outcome(%LearningRun{status: :applied}, _updates, [_ | _] = changes),
    do: %{label: "Outcome", value: saved(length(changes))}

  defp outcome(%LearningRun{status: :applied}, updates, []) when is_list(updates) do
    case Enum.split_with(updates, &(&1["action"] == "defer")) do
      {[], []} ->
        %{label: "Outcome", value: "Nothing saved", note: "the model found nothing new to keep"}

      {_deferred, []} ->
        %{label: "Outcome", value: "Nothing saved", note: "the model deferred every judgment"}

      {_deferred, saves} ->
        %{label: "Outcome", value: saved(length(saves))}
    end
  end

  defp outcome(%LearningRun{status: :applied}, nil, []), do: nil

  defp outcome(%LearningRun{status: status} = run, _updates, _changes)
       when status in [:rejected, :stale],
       do: %{label: "Outcome", value: "Nothing saved", note: LearningActivity.attempt_error(run)}

  defp outcome(%LearningRun{status: :responded}, _updates, _changes),
    do: %{label: "Outcome", value: "Ryker is checking the response"}

  defp outcome(_run, _updates, _changes), do: nil

  defp saved(1), do: "Saved 1 topic update"
  defp saved(count), do: "Saved #{count} topic updates"

  defp change(%{topic: topic, version: version, title: title}) do
    %{
      label: if(version == 1, do: "Created topic", else: "Updated topic"),
      value: title || "A topic whose text expired",
      href: ConversationMemory.topic_path(topic) <> "#update-#{version}",
      note: if(version > 1, do: "update #{version}")
    }
  end

  # An applied response whose topic revisions are no longer kept still says
  # which topics it wrote, from the response itself.
  defp unlinked_saves(%LearningRun{status: :applied}, updates, []) when is_list(updates) do
    for %{"action" => action} = update when action in ["create", "update"] <- updates do
      %{
        label: if(action == "create", do: "Created topic", else: "Updated topic"),
        value: present(update["title"]) || present(update["topic_key"]) || "A topic"
      }
    end
  end

  defp unlinked_saves(_run, _updates, _changes), do: []

  # A response that was not applied still says what it proposed.
  defp proposals(%LearningRun{status: :applied}, _updates), do: []
  defp proposals(_run, nil), do: []

  defp proposals(_run, updates) do
    for %{"action" => action} = update when action in ["create", "update"] <- updates do
      %{
        label: "Proposed, not saved",
        value: present(update["title"]) || present(update["topic_key"]) || "A topic",
        href: target_topic(update["target_ref"]),
        note: if(action == "update", do: "an update to this topic", else: "a new topic")
      }
    end
  end

  defp target_topic("knowledge:" <> id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> ConversationMemory.topic_path(id)
      :error -> nil
    end
  end

  defp target_topic(_ref), do: nil

  defp deferrals(nil), do: []

  defp deferrals(updates) do
    updates
    |> Enum.filter(&(&1["action"] == "defer"))
    |> Enum.map(&present(&1["reason"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&%{label: "Deferred", value: &1})
  end

  # An attempt can read several requests' messages; a page counts only its own.
  defp messages(run, context) do
    read = read(run)
    local = Enum.count(read, &MapSet.member?(context.local, &1))
    total = length(read)

    value =
      cond do
        total == 0 -> nil
        local == total -> plural(total, "message")
        context.scope == :message -> "#{plural(total, "message")}, this one among them"
        true -> "#{local} of #{total} from this request"
      end

    if value, do: %{label: "Messages read", value: value}
  end

  # The exact identities behind the card, for a reader checking the record:
  # identifiers and receipts stay here, never on the card's face.
  defp identity(run, context) do
    session = context.sessions[run.id]

    record =
      %{
        "validation_receipt" => run.validation_receipt,
        "stop_receipt" => run.stop_receipt,
        "error_code" => run.error_code
      }
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    %{
      facts:
        Enum.reject(
          [
            identifier("Attempt", run.id),
            identifier("Worker session", session && session.coop_session_id),
            identifier("Worker run", run.coop_turn_id),
            identifier("Prompt fingerprint", run.prompt_sha256),
            identifier("Response fingerprint", run.result_sha256),
            identifier("Diagnostic code", run.error_code),
            time("Prepared", run.inserted_at),
            time("Started", run.started_at),
            time("Applied", run.applied_at),
            time("Worker's run confirmed stopped", run.remote_stopped_at),
            time("Prompt and response removed", run.pruned_at)
          ],
          &is_nil/1
        ),
      link:
        if(run.batch_id,
          do: %{
            href: LearningActivity.path(run.batch_id),
            label: "All attempts for these messages"
          }
        ),
      record: if(record != %{}, do: record_text(record, context.secrets)),
      record_label: "Validation and stop receipts (JSON)"
    }
  end

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(count, noun), do: "#{count} #{noun}s"

  defp section(id, title, value, options),
    do: BackgroundCards.section(id, title, value, :learning, options)
end
