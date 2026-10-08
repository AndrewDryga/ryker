defmodule Ryker.ControlPlane.ModelRequests do
  @moduledoc "Bounded, explicitly sensitive read boundary for retained model requests."
  alias Ryker.Accounting
  alias Ryker.Admission
  alias Ryker.ControlPlane.{Activity, CallRun, ContextSearch, ContextSelection, EpisodeProjection}
  alias Ryker.ControlPlane.{BackgroundCards, RoutingReason, ThreadContext, Units, UsageProjection}
  alias Ryker.ControlPlane.{EpisodeTrace, FeedbackProjection, ImprovementRequests}
  alias Ryker.ControlPlane.EpisodeTrace.{CaseFile, Input, Step}
  alias Ryker.ControlPlane.{LearningRequests, PagedRelation, Paths, RepositoryNames}
  alias Ryker.CoopFleet
  alias Ryker.Crypto
  alias Ryker.Delivery
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.InspectionRedactor, as: Redactor
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack
  alias Ryker.UTCDateTime
  alias Ryker.Wording
  alias Ryker.Work

  @page_size 20
  @timeline_max_pages 10
  @response_page_size 10
  @artifact_bytes 2 * 1_024 * 1_024

  defmodule Reading do
    @moduledoc """
    What one page reads its model calls with: the rows it loaded once for all
    of them, the artifacts the reader opened, the secrets every artifact is
    redacted with, and whether the row being read has expired.
    """
    @enforce_keys [:secrets, :request_id, :opened]
    defstruct @enforce_keys ++
                [
                  execution_mode: nil,
                  sessions: %{},
                  admission_failures: %{},
                  previous_failures: %{},
                  title_updates: %{},
                  candidate_episodes: nil,
                  response_windows: %{},
                  responses: %{},
                  responses_limited: false,
                  expired: false
                ]
  end

  # Input identities address a specific incoming message, including messages
  # routed into an existing conversation rather than starting a new episode.
  def episode_ref("ingress-input:" <> id = ref) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %Ingress.Inbox.Entry{episode_id: episode_id}} when not is_nil(episode_id) <-
           Repo.fetch(Ingress.Inbox.Entry.Query.by_id(id)),
         {:ok, %Episodes.Episode{key: key}} <-
           Repo.fetch(Episodes.Episode.Query.by_id(episode_id)) do
      key
    else
      _ -> ref
    end
  end

  def episode_ref(ref), do: ref

  @doc "A bounded chronological document, with bulk-loaded custody and no per-request tool queries."
  def timeline(ref, params) do
    case Repo.fetch(Episodes.Episode.Query.by_key(episode_ref(ref))) do
      {:error, :not_found} -> :not_found
      {:ok, episode} -> timeline_for(episode, params)
    end
  end

  @doc """
  The artifact ids a reader has opened, from page params.

  Only artifacts a reader actually opened are prepared. Everything else keeps
  its size and digest so the card can say what is behind the disclosure
  without paying for it on every refresh.
  """
  def disclosed(%{"disclosed" => ids}) when is_list(ids),
    do: MapSet.new(Enum.filter(ids, &is_binary/1))

  def disclosed(_params), do: MapSet.new()

  defp timeline_for(episode, params) do
    disclosed = disclosed(params)
    page = min(PagedRelation.requested(params, "calls"), @timeline_max_pages)
    limit = page * @page_size

    turn_window =
      episode.id
      |> Work.Turn.Query.by_episode_id()
      |> Work.Turn.Query.ordered_by_recent()
      |> Work.Turn.Query.limit_to(limit + 1)
      |> Repo.all()

    turns =
      turn_window
      |> Enum.take(limit)
      |> include_selected_turn(selected_timeline_turn(episode, params))

    entry_window =
      episode.id
      |> Ingress.Inbox.Entry.Query.by_episode_id()
      |> Ingress.Inbox.Entry.Query.ordered_by_recent()
      |> Ingress.Inbox.Entry.Query.limit_to(limit + 1)
      |> Repo.all()

    entries = Enum.take(entry_window, limit)
    ids = Enum.map(entries, & &1.id)

    attempt_window =
      ids
      |> Admission.Attempt.Query.by_input_ids()
      |> Admission.Attempt.Query.ordered_by_recent()
      |> Admission.Attempt.Query.limit_to(limit + 1)
      |> Repo.all()

    attempts = Enum.take(attempt_window, limit)

    truncated =
      length(turn_window) > limit or length(entry_window) > limit or
        length(attempt_window) > limit

    admission_failures = admission_failures(ids, attempts)
    previous_failures = previous_failures(attempts, admission_failures)

    session_ids = Enum.map(turns, & &1.session_id)

    sessions =
      episode.id
      |> Work.Session.Query.by_episode_id()
      |> Work.Session.Query.by_ids(session_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    title_updates = title_updates(episode.id)

    reading =
      %Reading{
        secrets: Redactor.configured_secrets(),
        request_id: episode.id,
        execution_mode: episode.execution_mode,
        sessions: sessions,
        admission_failures: admission_failures,
        previous_failures: previous_failures,
        opened: disclosed,
        title_updates: title_updates
      }
      |> with_responses(turns, params)

    work =
      turns
      |> Enum.reject(&Work.Recovery.retained_absent_submission?/1)
      |> Enum.flat_map(fn turn ->
        request = inspect_turn(turn, reading)

        selection_event(turn, request) ++
          request_events(
            request,
            {:turn, turn.id},
            "request-#{turn.id}",
            turn.remote_finished_at,
            turn.candidate != nil or turn.validation_history != [] or turn.accepted_at != nil,
            Paths.request(episode.id) <> "#request-#{turn.id}",
            %{kind: :work, run: CallRun.from_turn(turn), title_update: title_updates[turn.id]}
          )
      end)

    by_input = Enum.group_by(attempts, & &1.input_id)

    retained_inputs =
      ids
      |> Admission.Attempt.Query.by_input_ids()
      |> Admission.Attempt.Query.select_input_ids()
      |> Repo.all()
      |> MapSet.new()

    admission =
      Enum.flat_map(entries, fn entry ->
        missing = if MapSet.member?(retained_inputs, entry.id), do: [], else: [nil]
        Enum.flat_map(Map.get(by_input, entry.id, missing), &admission_events(entry, &1, reading))
      end)

    # Background learning over this request's messages: the same model-request
    # cards, filed in the Learning chapter.
    learning =
      episode.id
      |> Ingress.Inbox.Entry.Query.by_episode_id()
      |> Ingress.Inbox.Entry.Query.ordered_by_occurred_at_desc()
      |> Ingress.Inbox.Entry.Query.limit_to(200)
      |> Ingress.Inbox.Entry.Query.select_ids()
      |> Repo.all()
      |> Enum.reverse()
      |> LearningRequests.entries(
        secrets: reading.secrets,
        disclosed: disclosed,
        scope: :request
      )

    {:ok,
     %{
       items: with_model_choice(work ++ admission ++ learning),
       truncated: truncated,
       call_history: %{
         page: page,
         shown:
           length(turns) + length(attempts) +
             Enum.count(entries, &(!MapSet.member?(retained_inputs, &1.id))),
         more: if(truncated && page < @timeline_max_pages, do: page + 1)
       }
     }}
  end

  # The title each accepted answer gave the request where it changed it: the
  # first answer that named the request, and each later one that renamed it.
  # An answer that kept the title, or set none, changed nothing (Andrew,
  # 2026-09-27: "do not show it if title stayed the same"). The request's title
  # is adopted from the accepted answer the same way
  # (`Ryker.Episodes.RoutingDigests.accept_title_in_transaction/2`).
  defp title_updates(episode_id) do
    episode_id
    |> Work.Turn.Query.accepted_titles(500)
    |> Repo.all()
    |> Enum.reduce({%{}, nil}, fn
      {id, title}, {updates, current} when is_binary(title) and title != current ->
        {Map.put(updates, id, title), title}

      _unchanged, acc ->
        acc
    end)
    |> elem(0)
  end

  # Current settings explain a retained request only when the exact template
  # digest matches. A reused name must never rewrite historical model evidence.
  defp with_model_choice(items) do
    bindings =
      case Settings.fetch() do
        {:ok, snapshot} ->
          Map.new(
            CoopFleet.JobTemplates.from_settings(snapshot),
            &{{&1.policy_name, &1.policy_digest}, &1}
          )

        _unavailable ->
          %{}
      end

    Enum.map(items, fn
      %{kind: :request, policy: policy} = item when is_binary(policy) ->
        binding = bindings[{policy, item[:policy_digest]}]

        Map.put(item, :model_choice, %{
          purpose: binding && binding.purpose,
          scope_kind: binding && binding.scope_kind,
          scope_name: scope_name(binding),
          scope_ref: binding && binding.scope_ref,
          settings: not is_nil(binding)
        })

      item ->
        item
    end)
  end

  # A repository's settings name it the way GitHub does (`RepositoryNames`).
  defp scope_name(%{scope_kind: :repository, scope_ref: ref}), do: RepositoryNames.name(ref)
  defp scope_name(_binding), do: nil

  defp selected_timeline_turn(episode, %{"attempt" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        id |> Work.Turn.Query.by_id() |> Work.Turn.Query.by_episode_id(episode.id) |> Repo.peek()

      :error ->
        nil
    end
  end

  defp selected_timeline_turn(_episode, _params), do: nil

  defp include_selected_turn(turns, nil), do: turns

  defp include_selected_turn(turns, selected) do
    [selected | turns]
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(&{&1.inserted_at, &1.id}, :desc)
  end

  defp admission_events(entry, attempt, reading) do
    generation = if attempt, do: attempt.generation, else: entry.execution_generation
    request = inspect_entry(entry, attempt, generation, reading)
    request = %{request | at: if(attempt, do: attempt.inserted_at, else: entry.inserted_at)}
    failure = if attempt, do: reading.admission_failures[attempt.id]
    completed = admission_completed_at(attempt)

    search_event(entry, attempt) ++
      request_events(
        request,
        {:input, entry.id},
        "admission-#{entry.id}-#{generation}",
        completed,
        attempt != nil and attempt.phase in ~w(response_received host_validation committed),
        Paths.request(reading.request_id) <> "#admission-#{entry.id}-#{generation}",
        %{
          failure: failure,
          kind: :admission,
          run: CallRun.from_attempt(attempt),
          retried_after: attempt && reading.previous_failures[attempt.id]
        }
      )
  end

  # How Ryker gathered earlier work and memory is its own step, before the
  # briefing that shows what the model was sent. Only the current attempt's
  # snapshot is kept, so an older attempt has no search card rather than a
  # newer attempt's search.
  defp search_event(
         %Ingress.Inbox.Entry{} = entry,
         %Admission.Attempt{generation: generation} = attempt
       )
       when generation == entry.execution_generation do
    case ContextSearch.present(entry.admission_context) do
      nil ->
        []

      search ->
        at = attempt.inserted_at
        id = "search-#{entry.id}-#{generation}"

        [
          %{
            id: "event-" <> id,
            owner: {:input, entry.id},
            at: at,
            sort_at: at,
            kind: :event,
            band: :routing,
            step:
              Step.step(id, :routing, at, %{
                actor: "Ryker",
                owner: {:input, entry.id},
                input_id: entry.id,
                search: search,
                details: [],
                stage: "Search",
                summary: nil,
                title: "Search for related history"
              })
          }
        ]
    end
  end

  defp search_event(_entry, _attempt), do: []

  # What a Work turn was sent was chosen before its briefing; the choice and
  # what it left out are their own card, first.
  defp selection_event(%Work.Turn{} = turn, request) do
    context = request.sections |> Enum.find(&(&1.id == "context")) |> section_document()

    case ContextSelection.present(turn.selection_ledger, context) do
      nil ->
        []

      selection ->
        id = "selection-#{turn.id}"

        [
          %{
            id: "event-" <> id,
            owner: {:turn, turn.id},
            at: request.at,
            sort_at: request.at,
            kind: :event,
            band: :work,
            step:
              Step.step(id, :work, request.at, %{
                actor: "Ryker",
                owner: {:turn, turn.id},
                search: selection,
                details: [],
                stage: "Selection",
                summary: nil,
                title: "Context selection"
              })
          }
        ]
    end
  end

  defp section_document(%{artifact: %{state: :retained, truncated: false, text: text}})
       when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = document} -> document
      _other -> nil
    end
  end

  defp section_document(_section), do: nil

  defp admission_failures([], _attempts), do: %{}

  defp admission_failures(input_ids, attempts) do
    transitions =
      input_ids
      |> Ingress.InputCustodyTransition.Query.by_input_ids()
      |> Ingress.InputCustodyTransition.Query.by_kinds([:retry_scheduled, :blocked])
      |> Ingress.InputCustodyTransition.Query.ordered_by_occurred_at_and_sequence()
      |> Repo.all()
      |> Enum.group_by(& &1.input_id)

    # The failure that ended an attempt is the first retry or stop after its
    # answer came back. A transport timeout while it was still running only
    # reattached the same call, and a committed attempt ended in its decision.
    Map.new(attempts, fn attempt ->
      ended = admission_completed_at(attempt) || attempt.inserted_at

      failure =
        if attempt.phase != "committed" do
          transitions
          |> Map.get(attempt.input_id, [])
          |> Enum.find(&(DateTime.compare(&1.occurred_at, ended) != :lt))
        end

      {attempt.id, routing_failure(failure)}
    end)
  end

  # A retried routing call knows why the one before it ended: that failure
  # happened first, so naming it on the retry is not reading ahead.
  defp previous_failures(attempts, failures) do
    attempts
    |> Enum.group_by(& &1.input_id)
    |> Enum.flat_map(fn {_input, attempts} ->
      by_generation = Map.new(attempts, &{&1.generation, &1})

      for attempt <- attempts,
          %Admission.Attempt{} = previous <- [by_generation[attempt.generation - 1]],
          %{} = failure <- [failures[previous.id]] do
        {attempt.id,
         Map.merge(failure, %{
           generation: previous.generation,
           href: "#" <> failure_card(previous)
         })}
      end
    end)
    |> Map.new()
  end

  # The card a failed call is read on: its result card once the call had a
  # response or finished, else its request card.
  defp failure_card(previous) do
    card = "admission-#{previous.input_id}-#{previous.generation}"

    if previous.phase in ~w(response_received host_validation committed) or
         admission_completed_at(previous),
       do: card <> "-result",
       else: card
  end

  defp routing_failure(nil), do: nil

  defp routing_failure(transition) do
    explanation = Work.FailureCause.explain(transition.detail)

    %{
      code: transition.error_code,
      detail: transition.detail,
      summary:
        if(explanation,
          do: explanation.cause,
          else: Wording.words(transition.error_code)
        )
    }
  end

  defp admission_completed_at(%{milestones: %{"response_received" => at}}) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _offset} -> time
      _invalid -> nil
    end
  end

  defp admission_completed_at(_), do: nil

  defp request_events(
         request,
         owner,
         id,
         completed,
         has_result,
         href,
         metadata
       ) do
    kind = metadata.kind
    failure = Map.get(metadata, :failure)

    {submission, outcome} =
      Enum.split_with(
        request.sections,
        &(&1.id in ~w(input instructions context tools contract request))
      )

    start = %{
      id: id,
      owner: owner,
      at: request.at,
      sort_at: request.at,
      counts: Map.get(request, :counts, %{}),
      title: request.title,
      target: request.target,
      status: request.status,
      fingerprint: Map.get(request, :fingerprint),
      policy: Map.get(request, :policy),
      policy_digest: Map.get(request, :policy_digest),
      request_id: request.id,
      generation: Map.get(request, :generation),
      generations: Map.get(request, :generations),
      failure: failure,
      execution_mode: Map.get(request, :execution_mode),
      source_kind: kind,
      phase: :submission,
      sections: submission,
      # The briefing names Slack people while it is drawn; the names known
      # then are part of the entry, so a later one draws it again.
      names: Slack.Names.revision(),
      href: href,
      band: :ready,
      kind: :request
    }

    result =
      if completed || has_result,
        do: [
          Map.merge(start, %{
            id: id <> "-result",
            at: completed,
            sort_at: completed || request.at,
            band: if(kind == :admission, do: :ready, else: :answer),
            title: request.title <> " · result",
            phase: :result,
            sections: outcome,
            run: Map.get(metadata, :run),
            retried_after: Map.get(metadata, :retried_after),
            title_update: Map.get(metadata, :title_update)
          })
        ],
        else: []

    [start | result]
  end

  @doc """
  The page of one message that has no request of its own: what it says and
  who sent it, what routing decided and what Ryker sent, the cards that show
  how routing got there, the thread around it, and the background learning
  that read it. A message that became part of a request answers with that
  request's reference instead.
  """
  def project_input(id, params) when is_map(params) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, %Ingress.Inbox.Entry{} = entry} <- Repo.fetch(Ingress.Inbox.Entry.Query.by_id(id)) do
      secrets = Redactor.configured_secrets()
      disclosed = disclosed(params)
      now = DateTime.utc_now()
      message = CaseFile.input_message(entry, disclosed)

      responses =
        id
        |> Delivery.RoutingResponse.Query.by_input_id()
        |> Delivery.RoutingResponse.Query.ordered_by_position()
        |> Repo.all()

      {:ok,
       %{
         episode_ref: EpisodeProjection.key(entry.episode_id),
         # What people said about the answer routing sent by itself.
         feedback: FeedbackProjection.for_request({:input, id}),
         self_analysis:
           ImprovementRequests.entries([input_id: id], secrets: secrets, disclosed: disclosed),
         input_id: id,
         # The request page's header, for a message: what it says as people
         # read it, what happened to it in the words Activity uses, and where
         # to read it where it was sent.
         heading: %{
           title: CaseFile.message_heading(message),
           state: input_state(entry, now),
           received_at: entry.occurred_at || entry.inserted_at,
           source: Input.message_link(entry),
           conversation_link:
             Activity.conversation_link(
               entry.destination_transport,
               entry.destination_conversation_ref,
               entry.execution_mode
             ),
           thread_link: ThreadContext.link(entry)
         },
         message: message,
         metrics: %{response_ms: response_ms(entry, responses), cost: routing_cost(entry)},
         preparation: EpisodeTrace.input_preparation(entry),
         timeline: input_request_events(entry, disclosed, secrets),
         answer: routing_answer(entry, responses, message),
         learning:
           [entry.id]
           |> LearningRequests.entries(secrets: secrets, disclosed: disclosed, scope: :message)
           |> with_model_choice(),
         recovery: admission_recovery(entry),
         names: Slack.Names.revision()
       }}
    else
      _missing -> :not_found
    end
  end

  defp input_state(entry, now), do: Repo.one!(Activity.Query.input_state(entry.id, now))

  # From the message to the first answer or reaction reaching the
  # conversation, as a request's response time is measured.
  defp response_ms(%Ingress.Inbox.Entry{occurred_at: %DateTime{} = sent}, responses) do
    case for(
           %Delivery.RoutingResponse{status: :delivered, delivered_at: %DateTime{} = at} <-
             responses,
           do: at
         ) do
      [] -> nil
      delivered -> max(DateTime.diff(Enum.min(delivered, DateTime), sent, :millisecond), 0)
    end
  end

  defp response_ms(_entry, _responses), do: nil

  # Routing is the only spend a message without a request has.
  defp routing_cost(%Ingress.Inbox.Entry{id: id}) do
    totals =
      nil
      |> Accounting.Execution.Query.ledger("all")
      |> Accounting.Execution.Query.admission_calls(id)
      |> UsageProjection.totals()

    if totals.costed + totals.estimated > 0, do: Units.cost(totals)
  end

  # What Ryker sent without work, the last stage of a message routing handled
  # itself: each message as it reached the conversation and each reaction, in
  # the order routing wrote them, or why it stayed quiet.
  defp routing_answer(entry, [_first | _rest] = responses, message),
    do: Enum.map(responses, &routing_answer_entry(entry, &1, message))

  defp routing_answer(
         %Ingress.Inbox.Entry{status: :decided, decision_action: :ignore} = entry,
         [],
         _message
       ) do
    reason =
      case entry.decision_document do
        %{"reason" => reason} when is_binary(reason) -> RoutingReason.plain(reason)
        _none -> nil
      end

    [
      event_entry(
        Step.step("routing-quiet-#{entry.id}", :answer, decided_at(entry), %{
          actor: "Ryker",
          details: [],
          stage: "Answer",
          summary: reason || "Routing decided the message needed no response.",
          title: "Ryker stayed quiet"
        })
      )
    ]
  end

  defp routing_answer(_entry, [], _message), do: []

  defp routing_answer_entry(
         entry,
         %Delivery.RoutingResponse{kind: :message, status: :delivered} = response,
         message
       ) do
    text = Redactor.artifact(response.document["message"], max_bytes: 12_000)

    %{
      id: "routing-response-#{response.id}",
      kind: :message,
      at: response.delivered_at,
      band: :answer,
      message: %{
        id: response.id,
        title: "Quick reply",
        actor: "Ryker",
        at: response.delivered_at,
        status: "Sent",
        text: text.text,
        available: text.state == :retained,
        transport: entry.destination_transport,
        workspace: message[:workspace]
      }
    }
  end

  defp routing_answer_entry(_entry, %Delivery.RoutingResponse{} = response, _message),
    do: event_entry(routing_answer_step(response))

  # When routing's decision was saved, from the attempt that made it; the
  # message row's own timestamp moves whenever the row changes again.
  defp decided_at(entry) do
    with {:ok, %Admission.Attempt{milestones: %{"committed" => committed}}} <-
           Repo.fetch(Admission.Attempt.Query.by_generation(entry.id, entry.execution_generation)),
         {:ok, at, _offset} <- DateTime.from_iso8601(committed) do
      at
    else
      _not_recorded -> entry.updated_at
    end
  end

  defp event_entry(step), do: %{id: "event-#{step.id}", kind: :event, step: step, at: step.at}

  defp routing_answer_step(response) do
    {state, tone} =
      case response.status do
        :delivered -> {"Sent", :good}
        :pending -> {"Sending", nil}
        :blocked -> {"Stopped", :bad}
      end

    Step.step(
      "routing-response-#{response.id}",
      :answer,
      response.delivered_at || response.inserted_at,
      %{
        actor: "Ryker",
        details: [],
        stage: "Answer",
        state: state,
        summary: routing_answer_words(response),
        title: if(response.kind == :message, do: "Quick reply", else: "Reaction"),
        tone: tone
      }
    )
  end

  defp routing_answer_words(%Delivery.RoutingResponse{
         kind: :message,
         document: %{"message" => message}
       }),
       do: message

  defp routing_answer_words(%Delivery.RoutingResponse{
         kind: :reaction,
         document: %{"emoji_name" => emoji}
       }),
       do: ":#{emoji}:"

  defp input_request_events(entry, disclosed, secrets) do
    attempts =
      entry.id
      |> Admission.Attempt.Query.by_input_id()
      |> Admission.Attempt.Query.ordered_by_generation_desc()
      |> Admission.Attempt.Query.limit_to(@page_size)
      |> Repo.all()
      |> Enum.reverse()

    # A card stands for a routing attempt that ran. The next attempt of a
    # blocked or waiting input has none until it starts; the queue card and the
    # attention banner say what the input is waiting for. A decision whose
    # attempt records were never kept or have expired still shows its card.
    attempts =
      if attempts == [] and entry.status in [:decided, :superseded],
        do: [nil],
        else: attempts

    reading = %Reading{
      secrets: secrets,
      request_id: entry.id,
      execution_mode: entry.execution_mode,
      admission_failures: admission_failures([entry.id], Enum.reject(attempts, &is_nil/1)),
      opened: disclosed,
      candidate_episodes: candidate_episodes(entry.admission_context)
    }

    Enum.flat_map(attempts, &admission_events(entry, &1, reading))
  end

  defp inspect_turn(%Work.Turn{} = turn, %Reading{} = reading) do
    session = Map.fetch!(reading.sessions, turn.session_id)
    expired = not is_nil(turn.operational_pruned_at)
    reading = %{reading | expired: expired}
    submission = if expired, do: %{}, else: turn.submission || %{}
    prompt = BackgroundCards.decode(submission["prompt"])
    context = prompt["work"]
    work = if is_map(context), do: context, else: %{}

    tools =
      Map.take(work, ~w(controller_tools responder_state_tools source_and_action_tools workspace))

    sections = [
      section("instructions", "Ryker instructions", prompt["instructions"], reading),
      section("context", "Messages and selected context", context, reading),
      section(
        "tools",
        "Advertised tools and workspace scope",
        if(tools != %{}, do: tools),
        reading
      ),
      section("contract", "Required output contract", submission["output_schema"], reading),
      request_section(
        "Submitted prompt · sanitized raw view",
        submission["prompt"],
        "work-#{turn.id}-request",
        reading
      ),
      section("candidate", "Response to validate", unless(expired, do: turn.candidate), reading),
      validation_section(turn, reading),
      section(
        "delivery",
        "Validated response",
        unless(expired, do: turn.delivery_document),
        reading
      )
    ]

    %{
      id: turn.id,
      counts: work_counts(context),
      title: "Work request",
      at: turn.inserted_at,
      status: turn.status,
      target: turn.execution_target || "Execution target not recorded",
      policy: session.policy,
      policy_digest: session.policy_digest,
      fingerprint: turn.submission_fingerprint,
      execution_mode: reading.execution_mode,
      sections:
        Enum.map(sections, fn section ->
          section
          |> Map.put(:source_kind, :work)
          |> Map.put_new(:artifact_id, "work-#{turn.id}-#{section.id}")
        end)
    }
  end

  defp inspect_entry(%Ingress.Inbox.Entry{} = entry, attempt, generation, %Reading{} = reading) do
    expired = not is_nil(entry.operational_pruned_at)
    reading = %{reading | expired: expired}
    generation = min(generation, entry.execution_generation)
    submission = admission_submission(attempt, expired)

    prompt = BackgroundCards.decode(submission["prompt"])
    response = if not expired, do: attempt_value(attempt, :response)

    %{
      id: entry.id,
      counts: admission_counts(entry, prompt["context"], reading),
      title: "Admission · execution #{generation}",
      generation: generation,
      generations: entry.execution_generation,
      at: entry.inserted_at,
      status: entry.status,
      target: attempt_value(attempt, :execution_target) || "Execution target not recorded",
      policy: attempt_value(attempt, :policy) || "Admission",
      policy_digest: attempt_value(attempt, :policy_digest),
      fingerprint:
        attempt_value(attempt, :submission_fingerprint) || entry.admission_context_fingerprint,
      sections:
        entry
        |> admission_sections(attempt, submission, prompt, response, generation, reading)
        |> Enum.map(fn section ->
          section
          |> Map.put(:source_kind, :admission)
          |> Map.put_new(:artifact_id, "admission-#{entry.id}-#{generation}-#{section.id}")
        end)
    }
  end

  # Every counted partial row says what it counted over. Included comes from the
  # frozen context, which is the exact set that reached the model. Eligible and
  # omitted come from the ledger recorded while the selection was made; without
  # it the row says the selection was not recorded rather than implying zero.
  # The briefing counts what was sent. What the selection ledger says existed
  # but was not sent is the Context selection card's, before the briefing.
  defp work_counts(context) when is_map(context) do
    %{}
    |> put_continuity_counts(context)
    |> put_listed_counts(context)
  end

  defp work_counts(_context), do: %{}

  # Source notes and maintained topics are two different kinds of record, so
  # the continuity row names each count rather than summing them.
  defp put_continuity_counts(counts, context) do
    parts =
      for {key, label} <- [{"observations", "source note"}, {"knowledge", "saved topic"}],
          included = get_in(context, ["operator_context", "continuity", key]),
          is_list(included),
          do: Wording.count(length(included), label)

    case parts do
      [] -> counts
      parts -> Map.put(counts, "continuity", count(Enum.join(parts, " · "), true))
    end
  end

  defp put_listed_counts(counts, context) do
    Enum.reduce(
      [
        {"records", ["records"]},
        {"related_outcomes", ["related_outcomes"]},
        {"guidance", ["operator_context", "guidance"]},
        {"memory", ["operator_context", "memory"]},
        {"standing_assignments", ["operator_context", "standing_assignments"]}
      ],
      counts,
      fn {key, path}, counts ->
        case get_in(context, path) do
          included when is_list(included) ->
            Map.put(counts, key, count("#{length(included)} included", true))

          _absent ->
            counts
        end
      end
    )
  end

  # The briefing shows what the model was sent and counts only that; what the
  # search found and left out is the search card's, before it. Candidate refs
  # resolve to their episodes' timelines for links.
  defp admission_counts(entry, context, %Reading{candidate_episodes: resolved})
       when is_map(context) do
    %{"candidate_episodes" => resolved || candidate_episodes(entry.admission_context)}
  end

  defp admission_counts(_entry, _context, _reading), do: %{}

  # A candidate card shows what the router read: the digest and the first and
  # latest messages. The rest of that episode belongs to its own timeline, so
  # the card links there. Opaque candidate refs name the same episode in every
  # generation, so the current snapshot resolves them all.
  defp candidate_episodes(%{"candidates" => candidates}) when is_list(candidates) do
    refs =
      for %{"episode_id" => id, "episode_ref" => ref} <- candidates,
          is_binary(ref),
          {:ok, id} <- [Ecto.UUID.cast(id)],
          into: %{},
          do: {id, ref}

    if refs == %{},
      do: %{},
      else:
        refs
        |> Map.keys()
        |> Episodes.Episode.Query.by_ids()
        |> Episodes.Episode.Query.select_ids()
        |> Repo.all()
        |> Map.new(&{refs[&1], Paths.request(&1)})
  end

  defp candidate_episodes(_snapshot), do: %{}

  defp count(label, known?), do: %{label: label, known?: known?}

  defp with_responses(%Reading{} = reading, turns, params) do
    windows = Map.new(turns, &{&1.id, response_window(&1, params)})

    attempts =
      for turn <- turns,
          is_nil(turn.operational_pruned_at),
          numbers = window_attempts(windows[turn.id]),
          numbers != [],
          do: {turn.id, numbers}

    rows =
      attempts
      |> Work.CandidateResponse.Query.latest_of_attempts(@response_page_size)
      |> Repo.all()

    %{
      reading
      | response_windows: windows,
        responses: Map.new(rows, &{{&1.turn_id, &1.candidate_attempt}, &1}),
        responses_limited: length(rows) == @response_page_size
    }
  end

  defp window_attempts(window),
    do: for(%{"candidate_attempt" => attempt} <- window, is_integer(attempt), do: attempt)

  # The checks whose responses a turn's card loads: the latest page of them,
  # or the page an older response's link names.
  defp response_window(turn, params) do
    history = if is_list(turn.validation_history), do: turn.validation_history, else: []
    total = length(history)

    offset =
      if params["responses_page"] do
        pages = max(1, ceil(total / @response_page_size))
        (min(PagedRelation.requested(params, "responses_page"), pages) - 1) * @response_page_size
      else
        max(total - @response_page_size, 0)
      end

    Enum.slice(history, offset, @response_page_size)
  end

  defp validation_section(turn, %Reading{} = reading) do
    window = reading.response_windows[turn.id]

    responses =
      for %{"candidate_attempt" => attempt} <- window,
          is_integer(attempt),
          into: %{},
          do: {attempt, response_artifact(turn, attempt, reading)}

    history =
      unless reading.expired do
        %{
          "verdict" => turn.validation_intent,
          "history" => window,
          "candidate_attempt" => turn.candidate_attempt,
          "accepted_at" => UTCDateTime.iso8601(turn.accepted_at)
        }
      end

    "validation"
    |> section("Host validation and repair history", history, reading)
    |> Map.merge(%{
      responses: responses,
      response_links: response_links(turn, responses, reading)
    })
  end

  defp response_artifact(turn, attempt, %Reading{} = reading) do
    case reading.responses[{turn.id, attempt}] do
      %{body: body, sha256: digest, byte_size: bytes, operational_pruned_at: pruned_at} ->
        reading = %{reading | expired: reading.expired or not is_nil(pruned_at)}
        retained = unless reading.expired, do: body
        artifact = Redactor.artifact(retained, redaction(reading))

        if reading.expired || (artifact.sha256 == digest && artifact.bytes == bytes),
          do: artifact,
          else: Redactor.artifact(nil, redaction(reading))

      nil ->
        absent_response(reading)
    end
  end

  defp absent_response(%Reading{} = reading) do
    artifact = Redactor.artifact(nil, redaction(reading))

    if reading.responses_limited and not reading.expired,
      do: %{artifact | state: :not_loaded},
      else: artifact
  end

  defp response_links(turn, responses, %Reading{} = reading) do
    for {%{"candidate_attempt" => attempt, "candidate_sha256" => digest}, index} <-
          Enum.with_index(turn.validation_history || []),
        is_integer(attempt),
        into: %{} do
      artifact = responses[attempt]

      current? =
        artifact && artifact.state == :not_recorded && current_response?(turn, attempt, digest)

      artifact = linked_response(artifact, digest, current?)

      page = div(index, @response_page_size) + 1

      {"turn-#{turn.id}-validation-#{attempt}",
       %{
         attempt: attempt,
         prefix: "turn-#{turn.id}",
         artifact: artifact,
         # Only the answer that was accepted changed the title.
         title_update:
           if(turn.accepted_at && attempt == turn.candidate_attempt,
             do: reading.title_updates[turn.id]
           ),
         # An archived response is read in its own check's card, on the page of
         # checks that holds it. The latest answer with no archive of its own
         # is read where the timeline shows it: its model call's result card.
         href:
           if(current?,
             do: response_request_path(turn, reading, %{}) <> "#request-#{turn.id}-result",
             else:
               response_request_path(turn, reading, %{responses_page: page}) <>
                 "#turn-#{turn.id}-response-#{attempt}-body"
           )
       }}
    end
  end

  defp linked_response(artifact, digest, current?) do
    if artifact && !current? && artifact.state != :not_loaded &&
         (artifact.state != :retained || artifact.sha256 == digest),
       do: artifact
  end

  defp current_response?(
         %{operational_pruned_at: nil, candidate_attempt: attempt, candidate: body},
         attempt,
         digest
       )
       when is_binary(body),
       do: Crypto.sha256_hex(body) == digest

  defp current_response?(_turn, _attempt, _digest), do: false

  defp response_request_path(turn, %Reading{request_id: request_id}, params) do
    query = Map.put(params, :attempt, turn.id)
    Paths.query(Paths.request(request_id), query)
  end

  defp admission_recovery(%{status: :blocked} = entry) do
    %{
      summary: Redactor.artifact(entry.last_error_code || "Routing stopped", max_bytes: 200).text,
      href: Paths.action("admission", Ingress.Inbox.ref(entry), "rearm")
    }
  end

  defp admission_recovery(_), do: nil

  defp admission_sections(entry, attempt, submission, prompt, response, generation, reading) do
    expired = reading.expired

    [
      section("input", "Source input", unless(expired, do: entry.content), reading),
      section("instructions", "Ryker's routing instructions", prompt["instructions"], reading),
      section(
        "context",
        "What routing was given",
        unless(expired, do: prompt["context"]),
        reading
      ),
      # Only the current attempt's search is retained; an older attempt's card
      # must not show the snapshot a later attempt replaced it with.
      section(
        "routing",
        "Routing evidence",
        unless(expired or generation != entry.execution_generation,
          do: routing_evidence(entry)
        ),
        reading
      ),
      request_section(
        "Submitted prompt",
        submission["prompt"],
        "admission-#{entry.id}-#{generation}-request",
        reading
      ),
      section("contract", "Required output contract", submission["output_schema"], reading),
      section("response", "Observed model response", response, reading),
      section(
        "candidate",
        "Committed admission decision",
        unless(expired or generation != entry.execution_generation,
          do: entry.decision_document
        ),
        reading
      ),
      section(
        "progress",
        "Observed execution milestones",
        admission_milestones(attempt),
        reading
      ),
      section(
        "measurements",
        "Reported usage and timing",
        attempt_value(attempt, :measurements),
        reading
      )
    ]
  end

  # The shortlist the model saw is only half the story: which lanes were
  # searched, how many eligible episodes were examined, what was omitted and
  # why the cutoff fell where it did are host facts, recorded when the context
  # was frozen. Without them an operator cannot tell a bounded search from a
  # missing one.
  defp routing_evidence(%Ingress.Inbox.Entry{admission_context: %{} = snapshot}) do
    evidence = Map.take(snapshot, ["routing_receipt", "context_manifest"])
    if map_size(evidence) > 0, do: evidence
  end

  defp routing_evidence(_entry), do: nil

  defp admission_submission(%{operational_pruned_at: nil, submission: submission}, false),
    do: submission || %{}

  defp admission_submission(_attempt, _expired), do: %{}
  defp attempt_value(nil, _key), do: nil
  defp attempt_value(attempt, key), do: Map.get(attempt, key)
  defp admission_milestones(nil), do: nil

  defp admission_milestones(attempt),
    do: %{"phase" => attempt.phase, "milestones" => attempt.milestones}

  defp section(id, title, value, %Reading{} = reading) do
    artifact = Redactor.artifact(value, redaction(reading))
    %{id: id, title: title, artifact: artifact}
  end

  # The submitted prompt is read as sent, and prepared only once its reader
  # opens it: it is the largest artifact on the page.
  defp request_section(title, value, artifact_id, %Reading{} = reading) do
    options =
      [preserve_format: true, disclosed: MapSet.member?(reading.opened, artifact_id)] ++
        redaction(reading)

    artifact = Redactor.artifact(value, options)
    %{id: "request", artifact_id: artifact_id, title: title, artifact: artifact}
  end

  # Every artifact on a page is redacted with the same secrets and bound.
  defp redaction(%Reading{secrets: secrets, expired: expired}),
    do: [secrets: secrets, max_bytes: @artifact_bytes, expired: expired]
end
