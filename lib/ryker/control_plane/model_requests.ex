defmodule Ryker.ControlPlane.ModelRequests do
  @moduledoc "Bounded, explicitly sensitive read boundary for retained model requests."
  import Ecto.Query
  alias Ryker.Admission.{Attempt, Candidate}
  alias Ryker.ControlPlane.{Activity, EpisodeTrace, PagedRelation, WorkRecovery}
  alias Ryker.ControlPlane.InspectionRedactor, as: Redactor
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Ingress.{Inbox, InputCustodyTransition}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.{ActivityEvent, ActivityRetention, CandidateResponse, Session, Turn}
  alias Ryker.Work.FailureCause

  @page_size 20
  @timeline_max_pages 10
  @tool_page_size 30
  @response_page_size 10
  @tool_kinds ~w(tool.started tool.completed permission.decided activity.elided provider.backoff)

  def project(ref, params) when is_binary(ref) and byte_size(ref) <= 1_024 and is_map(params) do
    case Repo.get_by(Episode, key: ref) do
      %Episode{} = episode ->
        kind = if params["kind"] == "admission", do: :admission, else: :work

        base =
          if kind == :work,
            do: from(row in Turn, where: row.episode_id == ^episode.id),
            else: from(row in Entry, where: row.episode_id == ^episode.id)

        page =
          PagedRelation.read(
            from(row in base, select: %{id: row.id, status: row.status, at: row.inserted_at}),
            [desc: :inserted_at, desc: :id],
            "page",
            params,
            page_size: @page_size
          )

        case selected_row(base, params["attempt"], page.items) do
          :not_found ->
            :not_found

          selected ->
            options =
              [
                secrets: Redactor.configured_secrets(),
                episode_ref: episode.key,
                execution_mode: episode.execution_mode,
                candidate_disclosed: disclosed(params),
                tool_disclosed: disclosed(params)
              ]
              |> with_responses(List.wrap(selected), params)

            {:ok,
             %{
               episode_ref: episode.key,
               kind: kind,
               page: page.page,
               pages: page.pages,
               total: page.total,
               items: page.items,
               selected: inspect_row(selected, params, options)
             }}
        end

      _missing ->
        :not_found
    end
  end

  def project(_ref, _params), do: :not_found

  # Input identities address a specific incoming message, including messages
  # routed into an existing conversation rather than starting a new episode.
  def episode_ref("ingress-input:" <> id = ref) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Entry{episode_id: episode_id} when not is_nil(episode_id) <- Repo.get(Entry, id),
         %Episode{key: key} <- Repo.get(Episode, episode_id) do
      key
    else
      _ -> ref
    end
  end

  def episode_ref(ref), do: ref

  @doc "A bounded chronological document, with bulk-loaded custody and no per-request tool queries."
  def timeline(ref, params) do
    case Repo.get_by(Episode, key: episode_ref(ref)) do
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
      Repo.all(
        from(t in Turn,
          where: t.episode_id == ^episode.id,
          order_by: [desc: t.inserted_at, desc: t.id],
          limit: ^(limit + 1)
        )
      )

    turns =
      turn_window
      |> Enum.take(limit)
      |> include_selected_turn(selected_timeline_turn(episode, params))

    entry_window =
      Repo.all(
        from(e in Entry,
          where: e.episode_id == ^episode.id,
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: ^(limit + 1)
        )
      )

    entries = Enum.take(entry_window, limit)
    ids = Enum.map(entries, & &1.id)

    attempt_window =
      Repo.all(
        from(a in Attempt,
          where: a.input_id in ^ids,
          order_by: [desc: a.inserted_at, desc: a.id],
          limit: ^(limit + 1)
        )
      )

    attempts = Enum.take(attempt_window, limit)

    truncated =
      length(turn_window) > limit or length(entry_window) > limit or
        length(attempt_window) > limit

    admission_failures = admission_failures(ids, attempts)

    session_ids = Enum.map(turns, & &1.session_id)

    sessions =
      Repo.all(from(s in Session, where: s.episode_id == ^episode.id and s.id in ^session_ids))
      |> Map.new(&{&1.id, &1})

    options =
      [
        secrets: Redactor.configured_secrets(),
        max_bytes: 2 * 1_024 * 1_024,
        timeline: true,
        episode_ref: episode.key,
        execution_mode: episode.execution_mode,
        sessions: sessions,
        admission_failures: admission_failures,
        disclosed: disclosed
      ]
      |> with_responses(turns, params)

    work =
      turns
      |> Enum.reject(&WorkRecovery.retained_absent_submission?/1)
      |> Enum.flat_map(fn turn ->
        request = inspect_row(turn, response_params(turn, params), options)

        timing = [
          %{label: "Coop queue", value: milliseconds(turn.usage_queued_ms)},
          %{label: "Agent execution", value: milliseconds(turn.usage_provider_ms)},
          %{label: "Host processing", value: milliseconds(turn.usage_host_ms)}
        ]

        request_events(
          request,
          {:turn, turn.id},
          "request-#{turn.id}",
          turn.remote_finished_at,
          turn.candidate != nil or turn.validation_history != [] or turn.accepted_at != nil,
          timing,
          "/timeline/#{URI.encode_www_form(episode.key)}#request-#{turn.id}",
          %{kind: :work}
        )
      end)

    by_input = Enum.group_by(attempts, & &1.input_id)

    retained_inputs =
      Repo.all(from(a in Attempt, where: a.input_id in ^ids, distinct: true, select: a.input_id))
      |> MapSet.new()

    admission =
      Enum.flat_map(entries, fn entry ->
        missing = if MapSet.member?(retained_inputs, entry.id), do: [], else: [nil]
        Enum.flat_map(Map.get(by_input, entry.id, missing), &admission_events(entry, &1, options))
      end)

    {:ok,
     %{
       items: work ++ admission,
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

  defp selected_timeline_turn(episode, %{"attempt" => id}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        Repo.one(from(t in Turn, where: t.id == ^id and t.episode_id == ^episode.id))

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
    measurements = if attempt, do: attempt.measurements, else: %{}

    timing = [
      %{label: "Coop queue", value: milliseconds(measurements["usage_queued_ms"])},
      %{label: "Agent execution", value: milliseconds(measurements["usage_provider_ms"])},
      %{label: "Host processing", value: milliseconds(measurements["usage_host_ms"])}
    ]

    request_events(
      request,
      {:input, entry.id},
      "admission-#{entry.id}-#{generation}",
      completed,
      attempt != nil and attempt.phase in ~w(response_received host_validation committed),
      timing,
      "/timeline/#{URI.encode_www_form(options[:episode_ref])}#admission-#{entry.id}-#{generation}",
      %{failure: failure, kind: :admission}
    )
  end

  defp admission_failures([], _attempts), do: %{}

  defp admission_failures(input_ids, attempts) do
    transitions =
      Repo.all(
        from(transition in InputCustodyTransition,
          where:
            transition.input_id in ^input_ids and
              transition.kind in [:retry_scheduled, :blocked],
          order_by: [asc: transition.occurred_at, asc: transition.sequence]
        )
      )
      |> Enum.group_by(& &1.input_id)

    Map.new(attempts, fn attempt ->
      failure =
        transitions
        |> Map.get(attempt.input_id, [])
        |> Enum.find(&(DateTime.compare(&1.occurred_at, attempt.inserted_at) != :lt))

      {attempt.id, routing_failure(failure)}
    end)
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
         timing,
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
      request_id: request.id,
      generation: Map.get(request, :generation),
      generations: Map.get(request, :generations),
      failure: failure,
      coverage: request.coverage,
      execution_mode: Map.get(request, :execution_mode),
      source_kind: kind,
      phase: :submission,
      sections: submission,
      timing: [],
      href: href,
      band: :ready,
      kind: :request
    }

    result =
      if completed || has_result,
        do: [
          %{
            start
            | id: id <> "-result",
              at: completed,
              sort_at: completed || request.at,
              band: if(kind == :admission, do: :ready, else: :answer),
              title: request.title <> " · result",
              phase: :result,
              sections: outcome,
              timing: timing
          }
        ],
        else: []

    [start | result]
  end

  defp milliseconds(nil), do: "Not recorded"
  defp milliseconds(ms) when ms < 1_000, do: "#{ms} ms"
  defp milliseconds(ms), do: "#{Float.round(ms / 1_000, 1)} s"

  defp response_params(%Turn{id: id}, %{"attempt" => id} = params), do: params
  defp response_params(_turn, _params), do: %{}

  def project_input(id, params) when is_map(params) do
    with {:ok, id} <- Ecto.UUID.cast(id), %Entry{} = entry <- Repo.get(Entry, id) do
      options = [secrets: Redactor.configured_secrets(), candidate_disclosed: disclosed(params)]

      options =
        Keyword.put(
          options,
          :candidate_histories,
          candidate_histories(entry.admission_context || %{}, entry, options)
        )

      request = inspect_row(entry, params, options)

      {:ok,
       %{
         episode_ref:
           if(entry.episode_id,
             do: Repo.one(from(e in Episode, where: e.id == ^entry.episode_id, select: e.key))
           ),
         input_id: id,
         kind: :admission,
         page: 1,
         pages: 1,
         total: 1,
         items: [%{id: id, status: entry.status, at: entry.inserted_at}],
         # A message waiting on routing is an episode that has not started, so
         # the page it gets is the episode page's own heading rather than a
         # second design for the same thing.
         heading: %{
           title: EpisodeTrace.unrouted_title(entry),
           received_at: entry.occurred_at || entry.inserted_at,
           conversation_href:
             Activity.conversation_path(
               entry.destination_transport,
               entry.destination_conversation_ref
             )
         },
         preparation: EpisodeTrace.input_preparation(entry),
         timeline: input_request_events(entry, params, options),
         selected: request
       }}
    else
      _missing -> :not_found
    end
  end

  defp input_request_events(entry, params, shared_options) do
    attempts =
      Repo.all(
        from(attempt in Attempt,
          where: attempt.input_id == ^entry.id,
          order_by: [desc: attempt.generation],
          limit: @page_size
        )
      )
      |> Enum.reverse()

    attempts =
      if Enum.any?(attempts, &(&1.generation == entry.execution_generation)),
        do: attempts,
        else: attempts ++ [nil]

    disclosed = disclosed(params)

    options =
      [
        secrets: Redactor.configured_secrets(),
        max_bytes: 2 * 1_024 * 1_024,
        timeline: true,
        episode_ref: "ingress-input:#{entry.id}",
        execution_mode: entry.execution_mode,
        admission_failures: admission_failures([entry.id], Enum.reject(attempts, &is_nil/1)),
        disclosed: disclosed,
        tool_disclosed: disclosed
      ]
      |> Keyword.put(:candidate_histories, shared_options[:candidate_histories])

    Enum.flat_map(attempts, &admission_events(entry, &1, options))
  end

  defp selected_row(_base, nil, []), do: nil
  defp selected_row(base, nil, [first | _]), do: selected_row(base, first.id, [])

  defp selected_row(base, id, _rows) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         row when not is_nil(row) <- Repo.one(from(row in base, where: row.id == ^uuid)) do
      row
    else
      _missing -> :not_found
    end
  end

  defp request_session(turn, options) do
    if options[:sessions],
      do: Map.fetch!(options[:sessions], turn.session_id),
      else: Repo.get!(Session, turn.session_id)
  end

  defp inspect_row(nil, _params, _options), do: nil

  defp inspect_row(%Turn{} = turn, params, options) do
    session = request_session(turn, options)

    expired = not is_nil(turn.operational_pruned_at)
    options = Keyword.put(options, :expired, expired)
    submission = if expired, do: %{}, else: turn.submission || %{}
    prompt = decode(submission["prompt"])
    context = prompt["work"]

    tools =
      Map.take(
        if(is_map(context), do: context, else: %{}),
        ~w(responder_state_tools source_and_action_tools workspace)
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
      fingerprint: turn.submission_fingerprint,
      execution_mode: options[:execution_mode],
      sections:
        Enum.map(sections, fn section ->
          section
          |> Map.put(:source_kind, :work)
          |> Map.put_new(:artifact_id, "work-#{turn.id}-#{section.id}")
        end),
      coverage:
        "This is Ryker's retained submission. The Coop wrapper, provider-owned instructions, and full provider request are not recorded here. No private reasoning is displayed.",
      tools: tool_page(turn, params, options)
    }
  end

  defp inspect_row(%Entry{} = entry, params, options) do
    expired = not is_nil(entry.operational_pruned_at)
    options = Keyword.put(options, :expired, expired)

    generation =
      if params["generation"],
        do: min(PagedRelation.requested(params, "generation"), entry.execution_generation),
        else: entry.execution_generation

    attempt =
      if Keyword.has_key?(options, :attempt),
        do: options[:attempt],
        else: Repo.get_by(Attempt, input_id: entry.id, generation: generation)

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
      recovery: admission_recovery(entry),
      at: entry.inserted_at,
      status: entry.status,
      target: attempt_value(attempt, :execution_target) || "Execution target not recorded",
      policy: attempt_value(attempt, :policy) || "Admission",
      fingerprint:
        attempt_value(attempt, :submission_fingerprint) || entry.admission_context_fingerprint,
      coverage: admission_coverage(submission),
      sections:
        admission_sections(entry, attempt, submission, prompt, response, generation, options)
        |> Enum.map(fn section ->
          section
          |> Map.put(:source_kind, :admission)
          |> Map.put_new(:artifact_id, "admission-#{entry.id}-#{generation}-#{section.id}")
        end),
      tools: admission_tool_page(entry, generation, params, options)
    }
  end

  # Every counted partial row says what it counted over. Included comes from the
  # frozen context, which is the exact set that reached the model. Eligible and
  # omitted come from the ledger recorded while the selection was made; without
  # it the row says the selection was not recorded rather than implying zero.
  defp work_counts(turn, context) when is_map(context) do
    ledger = if is_map(turn.selection_ledger), do: turn.selection_ledger, else: %{}

    %{}
    |> put_message_counts(ledger, context)
    |> put_continuity_counts(ledger, context)
    |> put_listed_counts(ledger, context)
  end

  defp work_counts(_turn, _context), do: %{}

  defp put_message_counts(counts, ledger, context) do
    inputs = Map.get(ledger, "inputs", %{})

    case context do
      %{"current_inputs" => %{"items" => items}} ->
        Map.put(
          counts,
          "current_inputs",
          count(
            "#{length(items)} current" <>
              case inputs["earlier_not_resent"] do
                value when is_integer(value) and value > 0 ->
                  " · #{value} earlier not resent"

                _absent ->
                  ""
              end,
            Map.has_key?(inputs, "earlier_not_resent")
          )
        )

      %{"inputs" => %{"items" => items} = supplied} ->
        Map.put(counts, "inputs", full_message_count(inputs, items, supplied))

      _absent ->
        counts
    end
  end

  defp full_message_count(inputs, items, supplied) do
    current = Enum.count(items, & &1["current"])
    earlier = length(items) - current

    if is_integer(inputs["eligible"]) do
      count(
        "#{inputs["eligible"]} eligible · #{current} current · #{earlier} earlier included" <>
          omission_phrase(inputs["omitted_window"], "outside the history window") <>
          omission_phrase(inputs["omitted_fit"], "cut to fit"),
        true
      )
    else
      count(
        "#{current} current · #{earlier} earlier included" <>
          omission_phrase(supplied["omitted_count"], "omitted") <>
          " · selection not recorded",
        false
      )
    end
  end

  defp omission_phrase(value, reason) when is_integer(value) and value > 0,
    do: " · #{value} #{reason}"

  defp omission_phrase(_value, _reason), do: ""

  # Source notes and maintained topics are two different universes; summing
  # them into one eligible total would invent a set nobody selected over.
  defp put_continuity_counts(counts, ledger, context) do
    parts =
      for {key, label} <- [{"observations", "Source notes"}, {"knowledge", "Saved topics"}],
          included = get_in(context, ["operator_context", "continuity", key]),
          is_list(included) do
        case get_in(ledger, [key, "eligible"]) do
          eligible when is_integer(eligible) and eligible > length(included) ->
            {"#{label} #{length(included)} of #{eligible}", true}

          eligible when is_integer(eligible) ->
            {"#{label} #{length(included)}", true}

          _absent ->
            {"#{label} #{length(included)}", false}
        end
      end

    case parts do
      [] ->
        counts

      parts ->
        Map.put(
          counts,
          "continuity",
          count(Enum.map_join(parts, " · ", &elem(&1, 0)), Enum.all?(parts, &elem(&1, 1)))
        )
    end
  end

  defp put_listed_counts(counts, _ledger, context) do
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

  # Routing counts come from the host snapshot frozen with the attempt: how many
  # episodes the bounded search checked, how many it offered the model, and the
  # knowledge it recorded as omitted. Offered is not chosen; the model's choice
  # is a later fact on its own card.
  defp admission_counts(entry, context, options) when is_map(context) do
    snapshot =
      if options[:current_generation] != false and is_map(entry.admission_context),
        do: entry.admission_context,
        else: %{}

    offered = length(List.wrap(context["candidates"]))
    receipt = if is_map(snapshot["routing_receipt"]), do: snapshot["routing_receipt"], else: %{}
    eligible = receipt["examined"] || snapshot["conversation_episode_count"]
    omissions = length(List.wrap(snapshot["knowledge_omissions"]))

    %{
      "candidates" =>
        if is_integer(eligible) and eligible >= offered do
          excluded = eligible - offered

          count("#{offered}/#{eligible} supplied to routing", true)
          |> Map.put(:excluded, excluded)
          |> Map.put(:reason, candidate_exclusion_reason(receipt["cutoff_reason"]))
        else
          count("#{offered} supplied to routing · eligible set not recorded", false)
        end,
      "conversation_knowledge" =>
        count(
          "#{length(List.wrap(context["conversation_knowledge"]))} included" <>
            omission_phrase(omissions, "omitted"),
          true
        ),
      "conversation_observations" =>
        count("#{length(List.wrap(context["conversation_observations"]))} included", true),
      "input" => count("1 included", true),
      "candidate_histories" =>
        if(options[:current_generation] == false,
          do: %{},
          else: options[:candidate_histories] || candidate_histories(snapshot, entry, options)
        )
    }
  end

  defp admission_counts(_entry, _context, _options), do: %{}

  # Candidate cards first render only the first/latest previews that were in
  # the frozen model request. The wider retained episode history is inspection
  # context, not model input, so it is fetched only when its own disclosure is
  # opened. One ranked query serves every opened candidate in this admission.
  defp candidate_histories(snapshot, entry, options) do
    specs = candidate_history_specs(snapshot, entry)

    disclosed =
      Keyword.get_lazy(options, :candidate_disclosed, fn ->
        Keyword.get(options, :disclosed, MapSet.new())
      end)

    opened =
      Enum.filter(specs, fn spec ->
        not match?(%MapSet{}, disclosed) or MapSet.member?(disclosed, spec.artifact_id)
      end)

    rows = candidate_history_rows(opened)

    Map.new(specs, fn spec ->
      history =
        if spec in opened,
          do: retained_candidate_history(spec, Map.get(rows, spec.episode_id, []), options),
          else: %{"artifact_id" => spec.artifact_id, "state" => "collapsed"}

      {spec.ref, history}
    end)
  end

  defp candidate_history_specs(snapshot, entry) do
    with built_at when is_binary(built_at) <- snapshot["built_at"],
         {:ok, built_at, _offset} <- DateTime.from_iso8601(built_at) do
      snapshot
      |> Map.get("candidates", [])
      |> Enum.map(&candidate_history_spec(&1, entry.id, built_at))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.episode_id)
    else
      _ -> []
    end
  end

  defp candidate_history_spec(
         %{
           "episode_id" => episode_id,
           "episode_ref" => ref,
           "digest" => %{"covered_through" => covered_through} = digest
         },
         entry_id,
         built_at
       )
       when is_binary(ref) and is_binary(covered_through) do
    with {:ok, episode_id} <- Ecto.UUID.cast(episode_id),
         {:ok, cutoff, _offset} <- DateTime.from_iso8601(covered_through) do
      %{
        artifact_id: "candidate-history-#{entry_id}-#{episode_id}",
        built_at: built_at,
        cutoff: cutoff,
        episode_id: episode_id,
        ref: ref,
        total: digest["input_count"]
      }
    else
      _ -> nil
    end
  end

  defp candidate_history_spec(_candidate, _entry_id, _built_at), do: nil

  defp candidate_history_rows([]), do: %{}

  defp candidate_history_rows(specs) do
    predicate =
      Enum.reduce(specs, dynamic(false), fn spec, predicate ->
        dynamic(
          [event],
          ^predicate or
            (event.episode_id == ^spec.episode_id and event.occurred_at <= ^spec.cutoff and
               event.inserted_at <= ^spec.built_at)
        )
      end)

    ranked =
      from(event in Event,
        where: event.kind == :input_admitted,
        where: ^predicate,
        select: %{
          id: event.id,
          episode_id: event.episode_id,
          occurred_at: event.occurred_at,
          payload: event.payload,
          sequence: event.sequence,
          first_rank:
            over(row_number(),
              partition_by: event.episode_id,
              order_by: [asc: event.sequence, asc: event.id]
            ),
          recent_rank:
            over(row_number(),
              partition_by: event.episode_id,
              order_by: [desc: event.sequence, desc: event.id]
            )
        }
      )

    Repo.all(
      from(event in subquery(ranked),
        join: input in Entry,
        on:
          input.episode_id == event.episode_id and
            input.native_input_id ==
              fragment("(?::jsonb)->'payload'->>'native_input_id'", event.payload) and
            input.source_kind ==
              fragment("(?::jsonb)->'payload'->'source'->>'kind'", event.payload) and
            input.source_ref ==
              fragment("(?::jsonb)->'payload'->'source'->>'ref'", event.payload) and
            input.event_ref ==
              fragment("(?::jsonb)->'payload'->>'event_ref'", event.payload),
        where: is_nil(input.operational_pruned_at),
        where: event.first_rank == 1 or event.recent_rank <= 19,
        order_by: [asc: event.episode_id, asc: event.sequence, asc: event.id]
      )
    )
    |> Enum.group_by(& &1.episode_id)
  end

  defp retained_candidate_history(spec, rows, options) do
    items =
      rows
      |> Enum.map(fn row ->
        case Candidate.event_preview(row) do
          %{} = preview -> Map.put(preview, "history_position", row.first_rank)
          nil -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    omitted = if is_integer(spec.total), do: max(spec.total - length(items), 0), else: 0

    value = %{
      "artifact_id" => spec.artifact_id,
      "items" => items,
      "omitted" => omitted,
      "state" => "retained"
    }

    case Redactor.artifact(value, secrets: options[:secrets]) do
      %{state: :retained, text: text} ->
        case Jason.decode(text) do
          {:ok, redacted} when is_map(redacted) -> redacted
          _ -> %{"artifact_id" => spec.artifact_id, "state" => "collapsed"}
        end

      _ ->
        %{"artifact_id" => spec.artifact_id, "state" => "collapsed"}
    end
  end

  defp candidate_exclusion_reason("limit"), do: "Shortlist limit reached."

  defp candidate_exclusion_reason(reason) when is_binary(reason) and reason != "",
    do: reason |> String.replace("_", " ") |> String.capitalize() |> Kernel.<>(".")

  defp candidate_exclusion_reason(_reason),
    do: "The remaining eligible candidates were not supplied."

  defp count(label, known?), do: %{label: label, known?: known?}

  defp with_responses(options, rows, params) do
    turns = Enum.filter(rows, &match?(%Turn{}, &1))
    windows = Map.new(turns, &{&1.id, response_window(&1, params, options[:timeline])})

    predicate =
      Enum.reduce(turns, dynamic(false), fn turn, predicate ->
        attempts =
          for %{"candidate_attempt" => attempt} <- windows[turn.id].entries,
              is_integer(attempt),
              do: attempt

        if is_nil(turn.operational_pruned_at) && attempts != [],
          do:
            dynamic(
              [response],
              ^predicate or
                (response.turn_id == ^turn.id and response.candidate_attempt in ^attempts)
            ),
          else: predicate
      end)

    rows =
      Repo.all(
        from(response in CandidateResponse,
          join: owner in Turn,
          on: owner.id == response.turn_id,
          where: ^predicate,
          where: is_nil(owner.operational_pruned_at),
          order_by: [
            desc: response.recorded_at,
            desc: response.turn_id,
            desc: response.candidate_attempt
          ],
          limit: @response_page_size,
          select: response
        )
      )

    Keyword.merge(options,
      response_windows: windows,
      responses: Map.new(rows, &{{&1.turn_id, &1.candidate_attempt}, &1}),
      responses_limited: options[:timeline] && length(rows) == @response_page_size
    )
  end

  defp response_window(turn, params, timeline?) do
    history = if is_list(turn.validation_history), do: turn.validation_history, else: []
    total = length(history)
    pages = max(1, ceil(total / @response_page_size))
    selected = if timeline?, do: pages, else: 1

    page =
      if params["responses_page"],
        do: min(PagedRelation.requested(params, "responses_page"), pages),
        else: selected

    offset =
      if timeline? && !params["responses_page"],
        do: max(total - @response_page_size, 0),
        else: (page - 1) * @response_page_size

    %{
      entries: Enum.slice(history, offset, @response_page_size),
      page: page,
      pages: pages,
      total: total,
      first: min(offset + 1, total),
      last: min(offset + @response_page_size, total)
    }
  end

  defp validation_section(turn, options) do
    window = Keyword.fetch!(options, :response_windows)[turn.id]
    expired = options[:expired]

    responses =
      for %{"candidate_attempt" => attempt} <- window.entries,
          is_integer(attempt),
          into: %{},
          do: {attempt, response_artifact(turn, attempt, options)}

    section(
      "validation",
      "Host validation and repair history",
      unless(expired,
        do: %{
          "verdict" => turn.validation_intent,
          "history" => window.entries,
          "candidate_attempt" => turn.candidate_attempt,
          "accepted_at" => iso(turn.accepted_at)
        }
      ),
      options
    )
    |> Map.merge(%{
      responses: responses,
      response_page:
        Map.merge(Map.delete(window, :entries), %{
          previous: response_page_link(turn, window.page - 1, window.pages, options),
          next: response_page_link(turn, window.page + 1, window.pages, options)
        }),
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
         href:
           if(current?,
             do:
               response_request_path(turn, options, %{section: "candidate"}) <>
                 "#turn-#{turn.id}-response-#{attempt}-body",
             else:
               response_page_link(turn, page, page, options) <>
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
       do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower) == digest

  defp current_response?(_turn, _attempt, _digest), do: false

  defp response_page_link(_turn, page, pages, _options) when page < 1 or page > pages, do: nil

  defp response_page_link(turn, page, _pages, options) do
    response_request_path(turn, options, %{responses_page: page, section: "validation"})
  end

  defp response_request_path(turn, options, params) do
    query = URI.encode_query(Map.put(params, :attempt, turn.id))

    "/timeline/#{URI.encode_www_form(options[:episode_ref])}?#{query}"
  end

  defp admission_recovery(%{status: :blocked} = entry) do
    %{
      summary:
        Redactor.artifact(entry.last_error_code || "Admission blocked", max_bytes: 200).text,
      href: "/actions/admission/#{URI.encode_www_form(Inbox.ref(entry))}/rearm"
    }
  end

  defp admission_recovery(_), do: nil

  defp admission_sections(entry, attempt, submission, prompt, response, generation, options) do
    expired = Keyword.fetch!(options, :expired)

    [
      section("input", "Source input", unless(expired, do: entry.content), options),
      section(
        "instructions",
        "Ryker admission instructions",
        prompt["instructions"],
        options
      ),
      section(
        "context",
        "Frozen admission context",
        unless(expired, do: prompt["context"]),
        options
      ),
      section(
        "routing",
        "Routing evidence",
        unless(expired, do: routing_evidence(entry)),
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

  defp admission_coverage(%{"prompt" => _prompt}),
    do:
      "This is the frozen Ryker admission submission, not the Coop wrapper or complete provider request. Milestones are observed facts, not percent-complete estimates."

  defp admission_coverage(_submission),
    do:
      "This execution has no retained submitted prompt. It may predate request capture or may not have submitted yet. Today's instructions are not substituted for missing history."

  defp tool_page(%{coop_turn_id: nil}, _params, _options),
    do: %{items: [], page: 1, pages: 1, total: 0}

  defp tool_page(turn, params, options) do
    if options[:timeline],
      do: %{items: [], page: 1, pages: 1, total: 0},
      else: query_tool_page(turn, params, options)
  end

  defp query_tool_page(turn, params, options) do
    query =
      from(event in ActivityEvent,
        where:
          event.episode_id == ^turn.episode_id and
            event.session_id == ^turn.session_id and event.coop_turn_id == ^turn.coop_turn_id and
            event.kind in @tool_kinds
      )

    activity_page(query, params, options)
  end

  defp admission_tool_page(entry, generation, params, options) do
    if options[:timeline] || options[:expired] do
      %{items: [], page: 1, pages: 1, total: 0}
    else
      query =
        from(event in ActivityEvent,
          join: session in Session,
          on: session.id == event.session_id,
          where:
            event.admission_input_id == ^entry.id and session.generation == ^generation and
              event.kind in @tool_kinds
        )

      activity_page(query, params, options)
    end
  end

  defp activity_page(query, params, options) do
    page =
      PagedRelation.read(
        ActivityRetention.visible(query),
        [asc: :sequence, asc: :id],
        "tools_page",
        params,
        page_size: @tool_page_size
      )

    items =
      Enum.map(page.items, fn event ->
        artifact_id = "tool-#{event.id}"

        %{
          id: event.id,
          artifact_id: artifact_id,
          kind: event.kind,
          at: event.occurred_at,
          artifact:
            Redactor.artifact(
              event.payload,
              options
              |> Keyword.put(:max_bytes, 16 * 1_024)
              |> Keyword.put(:disclosed, tool_opened?(options, artifact_id))
            )
        }
      end)

    %{items: items, page: page.page, pages: page.pages, total: page.total}
  end

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

  # A retained tool payload is heavy and almost always closed, even on the page
  # that exists to inspect one model call. The prompt on that page is what the
  # reader navigated to; its payloads are not.
  defp tool_opened?(options, id) do
    case options[:tool_disclosed] do
      %MapSet{} = disclosed -> MapSet.member?(disclosed, id)
      _no_disclosure_tracking -> true
    end
  end

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
