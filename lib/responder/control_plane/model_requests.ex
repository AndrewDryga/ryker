defmodule Responder.ControlPlane.ModelRequests do
  @moduledoc "Bounded, explicitly sensitive read boundary for retained model requests."
  import Ecto.Query
  alias Responder.Admission.Attempt
  alias Responder.ControlPlane.InspectionRedactor, as: Redactor
  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Work.{ActivityEvent, Session, Turn}

  @page_size 20
  @tool_page_size 30
  @tool_kinds ~w(tool.started tool.completed permission.decided activity.elided provider.backoff)

  def project(ref, params) when is_binary(ref) and byte_size(ref) <= 1_024 and is_map(params) do
    case Repo.get_by(Episode, key: ref) do
      %Episode{} = episode ->
        kind = if params["kind"] == "admission", do: :admission, else: :work
        page = page(params["page"])

        base =
          if kind == :work,
            do: from(row in Turn, where: row.episode_id == ^episode.id),
            else: from(row in Entry, where: row.episode_id == ^episode.id)

        total = Repo.aggregate(base, :count)

        rows =
          Repo.all(
            from(row in base,
              order_by: [desc: row.inserted_at, desc: row.id],
              offset: ^((page - 1) * @page_size),
              limit: @page_size,
              select: %{id: row.id, status: row.status, at: row.inserted_at}
            )
          )

        case selected_row(base, params["attempt"], rows) do
          :not_found ->
            :not_found

          selected ->
            options = [secrets: Redactor.configured_secrets()]

            {:ok,
             %{
               episode_ref: episode.key,
               kind: kind,
               page: page,
               pages: max(1, ceil(total / @page_size)),
               total: total,
               items: rows,
               selected: inspect_row(selected, params, options)
             }}
        end

      _missing ->
        :not_found
    end
  end

  def project(_ref, _params), do: :not_found

  @doc "A bounded chronological document, with bulk-loaded custody and no per-request tool queries."
  def timeline(ref, _params) do
    case Repo.get_by(Episode, key: ref) do
      nil -> :not_found
      episode -> timeline_for(episode)
    end
  end

  defp timeline_for(episode) do
    turns =
      Repo.all(
        from(t in Turn,
          where: t.episode_id == ^episode.id,
          order_by: [desc: t.inserted_at, desc: t.id],
          limit: 21
        )
      )

    entries =
      Repo.all(
        from(e in Entry,
          where: e.episode_id == ^episode.id,
          order_by: [desc: e.inserted_at, desc: e.id],
          limit: 21
        )
      )

    ids = Enum.map(Enum.take(entries, 20), & &1.id)

    attempts =
      Repo.all(
        from(a in Attempt,
          where: a.input_id in ^ids,
          order_by: [desc: a.inserted_at, desc: a.id],
          limit: 21
        )
      )

    session_ids = Enum.map(Enum.take(turns, 20), & &1.session_id)

    sessions =
      Repo.all(from(s in Session, where: s.episode_id == ^episode.id and s.id in ^session_ids))
      |> Map.new(&{&1.id, &1})

    options = [
      secrets: Redactor.configured_secrets(),
      max_bytes: 16_384,
      timeline: true,
      sessions: sessions
    ]

    work =
      Enum.flat_map(Enum.take(turns, 20), fn turn ->
        request = inspect_row(turn, %{}, options)

        timing = [
          %{label: "Coop queue", value: milliseconds(turn.usage_queued_ms)},
          %{label: "Agent execution", value: milliseconds(turn.usage_provider_ms)},
          %{label: "Host processing", value: milliseconds(turn.usage_host_ms)}
        ]

        request_events(
          request,
          "request-#{turn.id}",
          turn.remote_finished_at,
          turn.candidate != nil or turn.validation_history != [] or turn.accepted_at != nil,
          timing,
          "/episodes/#{URI.encode_www_form(episode.key)}/requests?attempt=#{turn.id}",
          :work
        )
      end)

    by_input = Enum.group_by(Enum.take(attempts, 20), & &1.input_id)

    retained_inputs =
      Repo.all(from(a in Attempt, where: a.input_id in ^ids, distinct: true, select: a.input_id))
      |> MapSet.new()

    admission =
      Enum.flat_map(Enum.take(entries, 20), fn entry ->
        missing = if MapSet.member?(retained_inputs, entry.id), do: [], else: [nil]
        Enum.flat_map(Map.get(by_input, entry.id, missing), &admission_events(entry, &1, options))
      end)

    {:ok,
     %{
       items: work ++ admission,
       truncated: length(turns) > 20 or length(entries) > 20 or length(attempts) > 20
     }}
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
    completed = admission_completed_at(attempt)
    measurements = if attempt, do: attempt.measurements, else: %{}

    timing = [
      %{label: "Coop queue", value: milliseconds(measurements["usage_queued_ms"])},
      %{label: "Agent execution", value: milliseconds(measurements["usage_provider_ms"])},
      %{label: "Host processing", value: milliseconds(measurements["usage_host_ms"])}
    ]

    request_events(
      request,
      "admission-#{entry.id}-#{generation}",
      completed,
      attempt != nil and attempt.phase in ~w(response_received host_validation committed),
      timing,
      "/admission/#{entry.id}?generation=#{generation}",
      :admission
    )
  end

  defp admission_completed_at(%{milestones: %{"response_received" => at}}) do
    case DateTime.from_iso8601(at) do
      {:ok, time, _offset} -> time
      _invalid -> nil
    end
  end

  defp admission_completed_at(_), do: nil

  defp request_events(request, id, completed, has_result, timing, href, kind) do
    {submission, outcome} =
      Enum.split_with(
        request.sections,
        &(&1.id in ~w(input instructions context tools contract request))
      )

    start = %{
      id: id,
      at: request.at,
      title: request.title,
      target: request.target,
      status: request.status,
      coverage: request.coverage,
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

  def project_input(id, params) when is_map(params) do
    with {:ok, id} <- Ecto.UUID.cast(id), %Entry{} = entry <- Repo.get(Entry, id) do
      {:ok,
       %{
         episode_ref: nil,
         input_id: id,
         kind: :admission,
         page: 1,
         pages: 1,
         total: 1,
         items: [%{id: id, status: entry.status, at: entry.inserted_at}],
         selected: inspect_row(entry, params, secrets: Redactor.configured_secrets())
       }}
    else
      _missing -> :not_found
    end
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
      section("instructions", "Responder instructions", prompt["instructions"], options),
      section("context", "Messages and selected context", context, options),
      section(
        "tools",
        "Advertised tools and workspace scope",
        if(tools != %{}, do: tools),
        options
      ),
      section("contract", "Required output contract", submission["output_schema"], options),
      section("request", "Submitted prompt · sanitized raw view", submission["prompt"], options),
      section(
        "candidate",
        "Model candidate · not a delivery receipt",
        unless(expired, do: turn.candidate),
        options
      ),
      section(
        "validation",
        "Host validation and repair history",
        unless(expired,
          do: %{
            "verdict" => turn.validation_intent,
            "history" => turn.validation_history,
            "candidate_attempt" => turn.candidate_attempt,
            "accepted_at" => iso(turn.accepted_at)
          }
        ),
        options
      ),
      section(
        "delivery",
        "Host delivery document",
        unless(expired, do: turn.delivery_document),
        options
      )
    ]

    %{
      id: turn.id,
      title: "Work request",
      at: turn.inserted_at,
      status: turn.status,
      target: turn.execution_target || "Execution target not recorded",
      policy: session.policy,
      fingerprint: turn.submission_fingerprint,
      sections: Enum.map(sections, &Map.put(&1, :source_kind, :work)),
      coverage:
        "This is Responder's retained submission. The Coop wrapper, provider-owned instructions, and full provider request are not recorded here. No private reasoning is displayed.",
      tools: tool_page(turn, params, options)
    }
  end

  defp inspect_row(%Entry{} = entry, params, options) do
    expired = not is_nil(entry.operational_pruned_at)
    options = Keyword.put(options, :expired, expired)

    generation =
      if params["generation"],
        do: min(page(params["generation"]), entry.execution_generation),
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
        |> Enum.map(&Map.put(&1, :source_kind, :admission)),
      tools: %{items: [], page: 1, pages: 1, total: 0}
    }
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
        "Responder admission instructions",
        prompt["instructions"],
        options
      ),
      section(
        "context",
        "Frozen admission context",
        unless(expired, do: prompt["context"]),
        options
      ),
      section("request", "Submitted prompt", submission["prompt"], options),
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
      "This is the frozen Responder admission submission, not the Coop wrapper or complete provider request. Milestones are observed facts, not percent-complete estimates."

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

    total = Repo.aggregate(query, :count)
    page = page(params["tools_page"])

    items =
      Repo.all(
        from(event in query,
          order_by: [asc: event.sequence],
          offset: ^((page - 1) * @tool_page_size),
          limit: @tool_page_size
        )
      )
      |> Enum.map(fn event ->
        %{
          id: event.id,
          kind: event.kind,
          at: event.occurred_at,
          artifact: Redactor.artifact(event.payload, Keyword.put(options, :max_bytes, 16 * 1_024))
        }
      end)

    %{items: items, page: page, pages: max(1, ceil(total / @tool_page_size)), total: total}
  end

  defp section(id, title, value, options),
    do: %{id: id, title: title, artifact: Redactor.artifact(value, options)}

  defp decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  defp decode(_value), do: %{}

  defp page(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number in 1..10_000 -> number
      _invalid -> 1
    end
  end

  defp page(_value), do: 1
  defp iso(nil), do: nil
  defp iso(at), do: DateTime.to_iso8601(at)
end
