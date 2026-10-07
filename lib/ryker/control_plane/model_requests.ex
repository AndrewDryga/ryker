defmodule Ryker.ControlPlane.ModelRequests do
  @moduledoc "Bounded, explicitly sensitive read boundary for retained model requests."
  alias Ryker.Accounting.Execution
  alias Ryker.Admission.Attempt
  alias Ryker.ControlPlane.{Activity, CallRun, ContextSearch, ContextSelection}
  alias Ryker.ControlPlane.{EpisodeTrace, FeedbackProjection, ImprovementRequests}
  alias Ryker.ControlPlane.EpisodeTrace.{CaseFile, Input, Step}
  alias Ryker.ControlPlane.{LearningRequests, PagedRelation, Paths, RepositoryNames}
  alias Ryker.ControlPlane.{RoutingReason, ThreadContext, Units, UsageProjection}
  alias Ryker.CoopFleet.JobTemplates
  alias Ryker.Crypto
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.{Inbox, InputCustodyTransition}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor, as: Redactor
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack.Names
  alias Ryker.Work.{CandidateResponse, Recovery, Session, Turn}
  alias Ryker.Work.FailureCause

  @page_size 20
  @timeline_max_pages 10
  @response_page_size 10

  # Input identities address a specific incoming message, including messages
  # routed into an existing conversation rather than starting a new episode.
  def episode_ref("ingress-input:" <> id = ref) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Entry{episode_id: episode_id} when not is_nil(episode_id) <-
           Repo.one(Entry.Query.by_id(id)),
         %Episode{key: key} <- Repo.one(Episode.Query.by_id(episode_id)) do
      key
    else
      _ -> ref
    end
  end

  def episode_ref(ref), do: ref

  @doc "A bounded chronological document, with bulk-loaded custody and no per-request tool queries."
  def timeline(ref, params) do
    case Repo.one(Episode.Query.by_key(episode_ref(ref))) do
      nil -> :not_found
      episode -> timeline_for(episode, params)
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
      |> Turn.Query.by_episode_id()
      |> Turn.Query.ordered_by_recent()
      |> Turn.Query.limit_to(limit + 1)
      |> Repo.all()

    turns =
      turn_window
      |> Enum.take(limit)
      |> include_selected_turn(selected_timeline_turn(episode, params))

    entry_window =
      episode.id
      |> Entry.Query.by_episode_id()
      |> Entry.Query.ordered_by_recent()
      |> Entry.Query.limit_to(limit + 1)
      |> Repo.all()

    entries = Enum.take(entry_window, limit)
    ids = Enum.map(entries, & &1.id)

    attempt_window =
      ids
      |> Attempt.Query.by_input_ids()
      |> Attempt.Query.ordered_by_recent()
      |> Attempt.Query.limit_to(limit + 1)
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
      |> Session.Query.by_episode_id()
      |> Session.Query.by_ids(session_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    title_updates = title_updates(episode.id)

    options =
      [
        secrets: Redactor.configured_secrets(),
        max_bytes: 2 * 1_024 * 1_024,
        request_id: episode.id,
        execution_mode: episode.execution_mode,
        sessions: sessions,
        admission_failures: admission_failures,
        previous_failures: previous_failures,
        disclosed: disclosed,
        title_updates: title_updates
      ]
      |> with_responses(turns, params)

    work =
      turns
      |> Enum.reject(&Recovery.retained_absent_submission?/1)
      |> Enum.flat_map(fn turn ->
        request = inspect_row(turn, %{}, options)

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
      |> Attempt.Query.by_input_ids()
      |> Attempt.Query.select_input_ids()
      |> Repo.all()
      |> MapSet.new()

    admission =
      Enum.flat_map(entries, fn entry ->
        missing = if MapSet.member?(retained_inputs, entry.id), do: [], else: [nil]
        Enum.flat_map(Map.get(by_input, entry.id, missing), &admission_events(entry, &1, options))
      end)

    # Background learning over this request's messages: the same model-request
    # cards, filed in the Learning chapter.
    learning =
      episode.id
      |> Entry.Query.by_episode_id()
      |> Entry.Query.ordered_by_occurred_at_desc()
      |> Entry.Query.limit_to(200)
      |> Entry.Query.select_ids()
      |> Repo.all()
      |> Enum.reverse()
      |> LearningRequests.entries(
        secrets: options[:secrets],
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
    |> Turn.Query.accepted_titles(500)
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
          Map.new(JobTemplates.from_settings(snapshot), &{{&1.policy_name, &1.policy_digest}, &1})

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
        id |> Turn.Query.by_id() |> Turn.Query.by_episode_id(episode.id) |> Repo.one()

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

  defp admission_events(entry, attempt, options) do
    generation = if attempt, do: attempt.generation, else: entry.execution_generation

    request =
      inspect_row(
        entry,
        %{"generation" => to_string(generation)},
        Keyword.put(options, :attempt, attempt)
      )

    request = %{request | at: if(attempt, do: attempt.inserted_at, else: entry.inserted_at)}
    failure = if attempt, do: options[:admission_failures][attempt.id]
    completed = admission_completed_at(attempt)

    search_event(entry, attempt) ++
      request_events(
        request,
        {:input, entry.id},
        "admission-#{entry.id}-#{generation}",
        completed,
        attempt != nil and attempt.phase in ~w(response_received host_validation committed),
        Paths.request(options[:request_id]) <> "#admission-#{entry.id}-#{generation}",
        %{
          failure: failure,
          kind: :admission,
          run: CallRun.from_attempt(attempt),
          retried_after: attempt && (options[:previous_failures] || %{})[attempt.id]
        }
      )
  end

  # How Ryker gathered earlier work and memory is its own step, before the
  # briefing that shows what the model was sent. Only the current attempt's
  # snapshot is kept, so an older attempt has no search card rather than a
  # newer attempt's search.
  defp search_event(%Entry{} = entry, %Attempt{generation: generation} = attempt)
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
  defp selection_event(%Turn{} = turn, request) do
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
      |> InputCustodyTransition.Query.by_input_ids()
      |> InputCustodyTransition.Query.of_kinds([:retry_scheduled, :blocked])
      |> InputCustodyTransition.Query.ordered_by_occurred_at_and_sequence()
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
          %Attempt{} = previous <- [by_generation[attempt.generation - 1]],
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
    explanation = FailureCause.explain(transition.detail)

    %{
      code: transition.error_code,
      detail: transition.detail,
      summary:
        if(explanation,
          do: explanation.cause,
          else: transition.error_code |> to_string() |> String.replace("_", " ")
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
      names: Names.revision(),
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
    with {:ok, id} <- Ecto.UUID.cast(id), %Entry{} = entry <- Repo.one(Entry.Query.by_id(id)) do
      options = [
        secrets: Redactor.configured_secrets(),
        candidate_episodes: candidate_episodes(entry.admission_context)
      ]

      now = DateTime.utc_now()
      message = CaseFile.input_message(entry, disclosed(params))

      responses =
        id
        |> RoutingResponse.Query.by_input_id()
        |> RoutingResponse.Query.ordered_by_position()
        |> Repo.all()

      {:ok,
       %{
         episode_ref: episode_key(entry.episode_id),
         # What people said about the answer routing sent by itself.
         feedback: FeedbackProjection.for_request({:input, id}),
         self_analysis:
           ImprovementRequests.entries([input_id: id],
             secrets: options[:secrets],
             disclosed: disclosed(params)
           ),
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
         timeline: input_request_events(entry, params, options),
         answer: routing_answer(entry, responses, message),
         learning:
           [entry.id]
           |> LearningRequests.entries(
             secrets: options[:secrets],
             disclosed: disclosed(params),
             scope: :message
           )
           |> with_model_choice(),
         recovery: admission_recovery(entry),
         names: Names.revision()
       }}
    else
      _missing -> :not_found
    end
  end

  defp episode_key(nil), do: nil

  defp episode_key(episode_id),
    do: episode_id |> Episode.Query.by_id() |> Episode.Query.select_keys() |> Repo.one()

  defp input_state(entry, now), do: Repo.one!(Activity.Query.input_state(entry.id, now))

  # From the message to the first answer or reaction reaching the
  # conversation, as a request's response time is measured.
  defp response_ms(%Entry{occurred_at: %DateTime{} = sent}, responses) do
    case for(
           %RoutingResponse{status: :delivered, delivered_at: %DateTime{} = at} <- responses,
           do: at
         ) do
      [] -> nil
      delivered -> max(DateTime.diff(Enum.min(delivered, DateTime), sent, :millisecond), 0)
    end
  end

  defp response_ms(_entry, _responses), do: nil

  # Routing is the only spend a message without a request has.
  defp routing_cost(%Entry{id: id}) do
    totals =
      nil
      |> Execution.Query.ledger("all")
      |> Execution.Query.admission_calls(id)
      |> UsageProjection.totals()

    if totals.costed + totals.estimated > 0, do: Units.cost(totals)
  end

  # What Ryker sent without work, the last stage of a message routing handled
  # itself: each message as it reached the conversation and each reaction, in
  # the order routing wrote them, or why it stayed quiet.
  defp routing_answer(entry, [_first | _rest] = responses, message),
    do: Enum.map(responses, &routing_answer_entry(entry, &1, message))

  defp routing_answer(%Entry{status: :decided, decision_action: :ignore} = entry, [], _message) do
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
         %RoutingResponse{kind: :message, status: :delivered} = response,
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

  defp routing_answer_entry(_entry, %RoutingResponse{} = response, _message),
    do: event_entry(routing_answer_step(response))

  # When routing's decision was saved, from the attempt that made it; the
  # message row's own timestamp moves whenever the row changes again.
  defp decided_at(entry) do
    with %Attempt{milestones: %{"committed" => committed}} <-
           Repo.one(Attempt.Query.for_generation(entry.id, entry.execution_generation)),
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

  defp routing_answer_words(%RoutingResponse{kind: :message, document: %{"message" => message}}),
    do: message

  defp routing_answer_words(%RoutingResponse{
         kind: :reaction,
         document: %{"emoji_name" => emoji}
       }),
       do: ":#{emoji}:"

  defp input_request_events(entry, params, shared_options) do
    attempts =
      entry.id
      |> Attempt.Query.by_input_id()
      |> Attempt.Query.ordered_by_generation_desc()
      |> Attempt.Query.limit_to(@page_size)
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

    disclosed = disclosed(params)

    options =
      [
        secrets: Redactor.configured_secrets(),
        max_bytes: 2 * 1_024 * 1_024,
        request_id: entry.id,
        execution_mode: entry.execution_mode,
        admission_failures: admission_failures([entry.id], Enum.reject(attempts, &is_nil/1)),
        disclosed: disclosed
      ]
      |> Keyword.put(:candidate_episodes, shared_options[:candidate_episodes])

    Enum.flat_map(attempts, &admission_events(entry, &1, options))
  end

  defp inspect_row(%Turn{} = turn, _params, options) do
    session = Map.fetch!(Keyword.fetch!(options, :sessions), turn.session_id)

    expired = not is_nil(turn.operational_pruned_at)
    options = Keyword.put(options, :expired, expired)
    submission = if expired, do: %{}, else: turn.submission || %{}
    prompt = decode(submission["prompt"])
    context = prompt["work"]

    tools =
      Map.take(
        if(is_map(context), do: context, else: %{}),
        ~w(controller_tools responder_state_tools source_and_action_tools workspace)
      )

    sections = [
      section("instructions", "Ryker instructions", prompt["instructions"], options),
      section("context", "Messages and selected context", context, options),
      section(
        "tools",
        "Advertised tools and workspace scope",
        if(tools != %{}, do: tools),
        options
      ),
      section("contract", "Required output contract", submission["output_schema"], options),
      section(
        "request",
        "Submitted prompt · sanitized raw view",
        submission["prompt"],
        Keyword.put(options, :artifact_id, "work-#{turn.id}-request")
      ),
      section(
        "candidate",
        "Response to validate",
        unless(expired, do: turn.candidate),
        options
      ),
      validation_section(turn, options),
      section(
        "delivery",
        "Validated response",
        unless(expired, do: turn.delivery_document),
        options
      )
    ]

    %{
      id: turn.id,
      counts: work_counts(turn, context),
      title: "Work request",
      at: turn.inserted_at,
      status: turn.status,
      target: turn.execution_target || "Execution target not recorded",
      policy: session.policy,
      policy_digest: session.policy_digest,
      fingerprint: turn.submission_fingerprint,
      execution_mode: options[:execution_mode],
      sections:
        Enum.map(sections, fn section ->
          section
          |> Map.put(:source_kind, :work)
          |> Map.put_new(:artifact_id, "work-#{turn.id}-#{section.id}")
        end)
    }
  end

  defp inspect_row(%Entry{} = entry, params, options) do
    expired = not is_nil(entry.operational_pruned_at)
    options = Keyword.put(options, :expired, expired)

    generation = min(PagedRelation.requested(params, "generation"), entry.execution_generation)
    attempt = Keyword.fetch!(options, :attempt)

    submission = admission_submission(attempt, expired)

    prompt = decode(submission["prompt"])
    response = if not expired, do: attempt_value(attempt, :response)

    %{
      id: entry.id,
      counts:
        admission_counts(
          entry,
          prompt["context"],
          Keyword.put(options, :current_generation, generation == entry.execution_generation)
        ),
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
        admission_sections(entry, attempt, submission, prompt, response, generation, options)
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
  defp work_counts(_turn, context) when is_map(context) do
    %{}
    |> put_continuity_counts(context)
    |> put_listed_counts(context)
  end

  defp work_counts(_turn, _context), do: %{}

  # Source notes and maintained topics are two different kinds of record, so
  # the continuity row names each count rather than summing them.
  defp put_continuity_counts(counts, context) do
    parts =
      for {key, label} <- [{"observations", "source note"}, {"knowledge", "saved topic"}],
          included = get_in(context, ["operator_context", "continuity", key]),
          is_list(included),
          do: continuity_count(length(included), label)

    case parts do
      [] -> counts
      parts -> Map.put(counts, "continuity", count(Enum.join(parts, " · "), true))
    end
  end

  defp continuity_count(1, label), do: "1 #{label}"
  defp continuity_count(number, label), do: "#{number} #{label}s"

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
  defp admission_counts(entry, context, options) when is_map(context) do
    %{
      "candidate_episodes" =>
        options[:candidate_episodes] || candidate_episodes(entry.admission_context)
    }
  end

  defp admission_counts(_entry, _context, _options), do: %{}

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
        |> Episode.Query.by_ids()
        |> Episode.Query.select_ids()
        |> Repo.all()
        |> Map.new(&{refs[&1], Paths.request(&1)})
  end

  defp candidate_episodes(_snapshot), do: %{}

  defp count(label, known?), do: %{label: label, known?: known?}

  defp with_responses(options, turns, params) do
    windows = Map.new(turns, &{&1.id, response_window(&1, params)})

    attempts =
      for turn <- turns,
          is_nil(turn.operational_pruned_at),
          numbers = window_attempts(windows[turn.id]),
          numbers != [],
          do: {turn.id, numbers}

    rows =
      attempts
      |> CandidateResponse.Query.latest_of_attempts(@response_page_size)
      |> Repo.all()

    Keyword.merge(options,
      response_windows: windows,
      responses: Map.new(rows, &{{&1.turn_id, &1.candidate_attempt}, &1}),
      responses_limited: length(rows) == @response_page_size
    )
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

  defp validation_section(turn, options) do
    window = Keyword.fetch!(options, :response_windows)[turn.id]
    expired = options[:expired]

    responses =
      for %{"candidate_attempt" => attempt} <- window,
          is_integer(attempt),
          into: %{},
          do: {attempt, response_artifact(turn, attempt, options)}

    section(
      "validation",
      "Host validation and repair history",
      unless(expired,
        do: %{
          "verdict" => turn.validation_intent,
          "history" => window,
          "candidate_attempt" => turn.candidate_attempt,
          "accepted_at" => iso(turn.accepted_at)
        }
      ),
      options
    )
    |> Map.merge(%{
      responses: responses,
      response_links: response_links(turn, responses, options)
    })
  end

  defp response_artifact(turn, attempt, options) do
    case Keyword.fetch!(options, :responses)[{turn.id, attempt}] do
      %{body: body, sha256: digest, byte_size: bytes, operational_pruned_at: pruned_at} ->
        expired = options[:expired] || not is_nil(pruned_at)

        artifact =
          Redactor.artifact(unless(expired, do: body), Keyword.put(options, :expired, expired))

        if expired || (artifact.sha256 == digest && artifact.bytes == bytes),
          do: artifact,
          else: Redactor.artifact(nil, options)

      nil ->
        absent_response(options)
    end
  end

  defp absent_response(options) do
    artifact = Redactor.artifact(nil, options)

    if options[:responses_limited] && !options[:expired],
      do: %{artifact | state: :not_loaded},
      else: artifact
  end

  defp response_links(turn, responses, options) do
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
             do: (options[:title_updates] || %{})[turn.id]
           ),
         # An archived response is read in its own check's card, on the page of
         # checks that holds it. The latest answer with no archive of its own
         # is read where the timeline shows it: its model call's result card.
         href:
           if(current?,
             do: response_request_path(turn, options, %{}) <> "#request-#{turn.id}-result",
             else:
               response_request_path(turn, options, %{responses_page: page}) <>
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

  defp response_request_path(turn, options, params),
    do: Paths.query(Paths.request(options[:request_id]), Map.put(params, :attempt, turn.id))

  defp admission_recovery(%{status: :blocked} = entry) do
    %{
      summary: Redactor.artifact(entry.last_error_code || "Routing stopped", max_bytes: 200).text,
      href: Paths.action("admission", Inbox.ref(entry), "rearm")
    }
  end

  defp admission_recovery(_), do: nil

  defp admission_sections(entry, attempt, submission, prompt, response, generation, options) do
    expired = Keyword.fetch!(options, :expired)

    [
      section("input", "Source input", unless(expired, do: entry.content), options),
      section(
        "instructions",
        "Ryker's routing instructions",
        prompt["instructions"],
        options
      ),
      section(
        "context",
        "What routing was given",
        unless(expired, do: prompt["context"]),
        options
      ),
      # Only the current attempt's search is retained; an older attempt's card
      # must not show the snapshot a later attempt replaced it with.
      section(
        "routing",
        "Routing evidence",
        unless(expired or generation != entry.execution_generation,
          do: routing_evidence(entry)
        ),
        options
      ),
      section(
        "request",
        "Submitted prompt",
        submission["prompt"],
        Keyword.put(options, :artifact_id, "admission-#{entry.id}-#{generation}-request")
      ),
      section("contract", "Required output contract", submission["output_schema"], options),
      section("response", "Observed model response", response, options),
      section(
        "candidate",
        "Committed admission decision",
        unless(expired or generation != entry.execution_generation,
          do: entry.decision_document
        ),
        options
      ),
      section(
        "progress",
        "Observed execution milestones",
        admission_milestones(attempt),
        options
      ),
      section(
        "measurements",
        "Reported usage and timing",
        attempt_value(attempt, :measurements),
        options
      )
    ]
  end

  # The shortlist the model saw is only half the story: which lanes were
  # searched, how many eligible episodes were examined, what was omitted and
  # why the cutoff fell where it did are host facts, recorded when the context
  # was frozen. Without them an operator cannot tell a bounded search from a
  # missing one.
  defp routing_evidence(%Entry{admission_context: %{} = snapshot}) do
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

  defp section("request" = id, title, value, options) do
    artifact_id = Keyword.get(options, :artifact_id)

    %{
      id: id,
      artifact_id: artifact_id,
      title: title,
      artifact:
        Redactor.artifact(
          value,
          Keyword.merge(options,
            preserve_format: true,
            max_bytes: 2 * 1_024 * 1_024,
            disclosed: opened?(options, artifact_id)
          )
        )
    }
  end

  defp section(id, title, value, options),
    do: %{id: id, title: title, artifact: Redactor.artifact(value, options)}

  # An artifact with no identity cannot be opened again on the next refresh, so
  # it is never collapsed: a body a reader could not restore is worse than a
  # body they did not ask for.
  defp opened?(_options, nil), do: true

  defp opened?(options, id) do
    case options[:disclosed] do
      %MapSet{} = disclosed -> MapSet.member?(disclosed, id)
      _no_disclosure_tracking -> true
    end
  end

  defp decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  defp decode(_value), do: %{}

  defp iso(nil), do: nil
  defp iso(at), do: DateTime.to_iso8601(at)
end
