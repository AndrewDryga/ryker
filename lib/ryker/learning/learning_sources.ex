defmodule Ryker.Learning.LearningSources do
  @moduledoc "Bounded, host-owned source receipts carried across derived conversation memory."
  alias Ryker.{CanonicalJSON, Repo}
  alias Ryker.Config
  alias Ryker.Continuity.{ConversationRollup, ConversationSummary}
  alias Ryker.Episodes.Event
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Knowledge.KnowledgeRevision
  alias Ryker.Learning.{ConversationObservation, Observations, SourceDependency}
  alias Ryker.Publication.LifecycleEvent
  alias Ryker.Reference

  @maximum_sources 10_000
  @maximum_bytes 8 * 1_024 * 1_024
  # `publication-review` is a refused review sent back to its task's work
  # (`Ryker.Publication.FixLoop`): the host's own words and the gate's output.
  @system_source_refs ["ryker", "emisar", "publication-lifecycle", "publication-review"]
  @receipt_fields ~w(observation_id source_input_id revision fingerprint transport workspace_ref conversation_ref repository_ref visibility retained_at)
  @utc_timestamp_pattern ~S/\A[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[T ]([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.,][0-9]+)?(Z|[+]00(:?00)?|-00(00)?)\Z/

  # PostgreSQL also accepts relative times, infinity and non-UTC offsets. The
  # SQL prefilter must reject those before a malformed receipt spends a slot.
  # Calendar validity is still checked before casting; the locked host check
  # remains authoritative for the complete receipt.
  @doc false
  def utc_timestamp_pattern, do: @utc_timestamp_pattern

  @doc false
  def with_input_boundary(scope, %Ryker.Episodes.Episode{id: id} = episode)
      when is_binary(id) do
    Map.put(
      scope,
      :input_boundary,
      {episode.id, episode.next_sequence, episode.queued_input_refs}
    )
  end

  def with_input_boundary(scope, _destination), do: scope

  def merge(groups) do
    case resolve(groups) do
      {sources, _roots} -> sources
      nil -> nil
    end
  end

  defp resolve(groups) when is_list(groups) do
    with true <- Enum.all?(groups, &is_list/1),
         sources = List.flatten(groups),
         true <- Enum.all?(sources, &(valid_shape?(&1) or reference?(&1))),
         {references, raw} = Enum.split_with(sources, &reference?/1),
         sources =
           Enum.sort_by(Enum.uniq(references) ++ earliest_receipts(raw), &CanonicalJSON.encode!/1),
         true <-
           length(sources) <= @maximum_sources and
             byte_size(CanonicalJSON.encode!(sources)) <= @maximum_bytes,
         expanded when is_list(expanded) <- expand(sources) do
      {sources, expanded}
    else
      _ -> nil
    end
  end

  defp resolve(_), do: nil

  @doc "Expand host references to terminal receipts; no recursive dependency graph or truncation."
  def expand(sources) when is_list(sources) and length(sources) <= @maximum_sources do
    if Enum.all?(sources, &(valid_shape?(&1) or reference?(&1))) and
         byte_size(CanonicalJSON.encode!(sources)) <= @maximum_bytes do
      roots =
        if Enum.any?(sources, &reference?/1) do
          Repo.query!(
            """
            SELECT DISTINCT ON (CASE WHEN jsonb_typeof(r) = 'object' THEN r - 'retained_at' ELSE r END) r
            FROM ryker_learning_roots($1) r
            ORDER BY CASE WHEN jsonb_typeof(r) = 'object' THEN r - 'retained_at' ELSE r END,
              CASE WHEN pg_input_is_valid(r->>'retained_at', 'timestamptz')
                THEN (r->>'retained_at')::timestamptz ELSE '-infinity'::timestamptz END
            LIMIT 10001
            """,
            [
              CanonicalJSON.encode!(sources)
            ]
          ).rows
          |> Enum.map(&hd/1)
        else
          sources
        end

      bounded_roots(roots)
    end
  end

  def expand(_), do: nil

  defp bounded_roots(roots) do
    if length(roots) <= @maximum_sources and Enum.all?(roots, &valid_shape?/1) do
      roots = earliest_receipts(roots)
      if byte_size(CanonicalJSON.encode!(roots)) <= @maximum_bytes, do: roots
    end
  end

  def knowledge_reference(id, generation, version),
    do: %{
      "kind" => "knowledge_sources",
      "knowledge_id" => id,
      "generation" => generation,
      "through_version" => version
    }

  defp reference?(
         %{
           "kind" => "knowledge_sources",
           "knowledge_id" => id,
           "generation" => generation,
           "through_version" => version
         } = reference
       ) do
    map_size(reference) == 4 and Ecto.UUID.cast(id) == {:ok, id} and
      is_integer(generation) and generation in 1..9_223_372_036_854_775_807 and
      is_integer(version) and version in 1..9_223_372_036_854_775_807
  end

  defp reference?(_), do: false

  defp earliest_receipts(sources) do
    sources
    |> Enum.group_by(&Map.delete(&1, "retained_at"))
    |> Enum.map(fn {_identity, receipts} -> Enum.min_by(receipts, &retained_at/1, DateTime) end)
    |> Enum.sort_by(&CanonicalJSON.encode!/1)
  end

  def oldest(sources, fallback \\ nil) do
    sources = expand(sources) || []
    dates = for source <- sources, valid_shape?(source), do: retained_at(source)
    dates = if fallback, do: [fallback | dates], else: dates
    Enum.min(dates, DateTime, fn -> nil end)
  end

  defp retained_at(receipt) do
    {:ok, date, 0} = DateTime.from_iso8601(receipt["retained_at"])
    date
  end

  @doc """
  An input learning may still read: decided, not a deletion, its body neither
  pruned nor absent. Every learning step re-checks this on the exact rows.
  """
  @spec current_entry?(Entry.t()) :: boolean()
  def current_entry?(%Entry{} = entry) do
    entry.status == :decided and entry.event_kind != :delete and
      is_nil(entry.operational_pruned_at) and is_map(entry.content)
  end

  @doc "Derived prose requires at least one source; source-free host tasks do not."
  def sourced?([_ | _]), do: true
  def sourced?(_), do: false

  @doc "Exclude receiptless derived prose before bounded recall and compaction selection."
  def sourced(query), do: SourceDependency.Query.sourced(query)

  @doc "Filter inherited source eligibility before recall limits; locked validation still follows."
  def eligible(query, scope),
    do: SourceDependency.Query.eligible(query, scope, retention_seconds(), @utc_timestamp_pattern)

  defp future_inputs_absent?(roots, %{input_boundary: _} = scope) do
    roots
    |> CanonicalJSON.encode!()
    |> SourceDependency.Query.roots()
    |> SourceDependency.Query.without_future_inputs(scope)
    |> Repo.exists?()
  end

  defp future_inputs_absent?(_roots, _scope), do: true

  defp valid_shape?(receipt) when is_map(receipt) do
    Enum.sort(Map.keys(receipt)) == Enum.sort(@receipt_fields) and
      Enum.all?(
        ~w(observation_id source_input_id),
        &(Ecto.UUID.cast(receipt[&1]) == {:ok, receipt[&1]})
      ) and
      is_integer(receipt["revision"]) and receipt["revision"] > 0 and
      Reference.valid?(receipt["fingerprint"], 64) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, receipt["fingerprint"]) and
      scope_shape?(receipt) and timestamp?(receipt["retained_at"])
  end

  defp valid_shape?(_), do: false

  defp scope_shape?(receipt) do
    Enum.all?(~w(transport workspace_ref conversation_ref), &Reference.valid?(receipt[&1], 1024)) and
      (is_nil(receipt["repository_ref"]) or Reference.valid?(receipt["repository_ref"], 1024)) and
      receipt["visibility"] in ~w(public private direct conversation)
  end

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _, 0}, DateTime.from_iso8601(value))

  defp timestamp?(_), do: false

  def for_entry(entry) do
    identity = Observations.source_identity(entry)
    source = Repo.one(ConversationObservation.Query.by_identity(identity))

    case source do
      %{source_result_ref: "source-conflict:" <> _} ->
        nil

      # A forgotten message is never learned from again.
      %{forgotten_at: %DateTime{}} ->
        nil

      %{source_input_id: id, revision: revision}
      when id == entry.id and revision == entry.revision ->
        [receipt(source)]

      _ ->
        nil
    end
  end

  def for_source(source) do
    existing = Repo.one(ConversationObservation.Query.by_identity(source.identity_key))

    source = if existing, do: %{source | id: existing.id}, else: source

    source =
      if existing && existing.revision == source.revision &&
           existing.source_input_id == source.source_input_id,
         do: %{source | updated_at: existing.updated_at},
         else: source

    [receipt(source)]
  end

  def authorize_context(context, entry) do
    with {:ok, scope} <- Observations.locked_scope(entry, entry.repository_ref),
         true <- valid?(context.source_dependencies, scope) do
      context.source_dependencies
    else
      _ -> nil
    end
  end

  defp receipt(source) do
    %{
      "observation_id" => source.id,
      "source_input_id" => source.source_input_id,
      "revision" => source.revision,
      "fingerprint" => source.source_fingerprint,
      "transport" => source.transport,
      "workspace_ref" => source.workspace_ref,
      "conversation_ref" => source.conversation_ref,
      "repository_ref" => source.repository_ref,
      "visibility" => Atom.to_string(source.visibility),
      "retained_at" => DateTime.to_iso8601(source.updated_at)
    }
  end

  def freeze(context) do
    base =
      merge([for_entry(context.input_entry) | Enum.map(context.candidates, &candidate_sources/1)])

    fit(context, base)
  end

  defp fit(context, nil), do: %{context | source_dependencies: nil}

  defp fit(context, base) do
    sources =
      merge([base | Enum.map(context.observations ++ context.knowledge, &document_sources/1)])

    cond do
      is_list(sources) ->
        %{context | source_dependencies: sources}

      context.observations != [] ->
        fit(%{context | observations: Enum.drop(context.observations, -1)}, base)

      context.knowledge != [] ->
        omitted = List.last(context.knowledge)

        receipt =
          omitted
          |> Map.take(~w(source_ref version topic_key conversation_ref repository_ref))
          |> Map.put("reason", "source_capacity")

        fit(
          %{
            context
            | knowledge: Enum.drop(context.knowledge, -1),
              knowledge_omissions: context.knowledge_omissions ++ [receipt]
          },
          base
        )

      true ->
        %{context | source_dependencies: nil}
    end
  end

  defp candidate_sources(candidate),
    do: candidate.source_documents |> Enum.map(&input_sources/1) |> merge()

  defp input_sources(%{"event_kind" => "delete"}), do: nil
  defp input_sources(document), do: matching_input_sources(document)

  defp matching_input_sources(
         %{
           "source" => %{"kind" => kind, "ref" => ref},
           "native_input_id" => native,
           "revision" => revision,
           "content" => content
         } = document
       ) do
    identity =
      CanonicalJSON.digest(%{
        "source_kind" => kind,
        "source_ref" => ref,
        "native_input_id" => native
      })

    with %{} = source <- Repo.one(ConversationObservation.Query.by_identity(identity)),
         true <- source.revision == revision,
         true <- source_payload_matches?(source, document, content) do
      [receipt(source)]
    else
      _ -> nil
    end
  end

  defp matching_input_sources(_), do: nil

  defp source_payload_matches?(
         %{source_input_id: id, source_result_ref: "publication-feedback:" <> id},
         document,
         _content
       ) do
    case get_uuid(&LifecycleEvent.Query.by_id/1, id) do
      %LifecycleEvent{kind: :review_feedback, observation: observation} ->
        fields = ~w(source native_input_id revision event_kind content)
        Map.take(observation, fields) == Map.take(document, fields)

      _ ->
        false
    end
  end

  defp source_payload_matches?(%{source_result_ref: "publication-feedback:" <> _}, _, _),
    do: false

  defp source_payload_matches?(%{source_result_ref: "source-conflict:" <> _}, _, _),
    do: false

  defp source_payload_matches?(source, document, content) do
    case Repo.one(Entry.Query.by_id(source.source_input_id)) do
      %Entry{content: ^content, event_kind: kind} ->
        Atom.to_string(kind) == document["event_kind"]

      _ ->
        false
    end
  end

  @doc "Resolve raw Work ingress before its content is shortened for a briefing."
  def for_work_input(%{"event_kind" => "delete", "source" => %{}}), do: nil

  # These source type/ref pairs are authored only by host producers. The shipped
  # Slack, GitHub and webhook adapters fix their own outer source kinds; content
  # nested inside their envelopes can never select this no-ingress path.
  def for_work_input(%{
        "source" => %{"kind" => "system", "ref" => ref},
        "actor" => %{"kind" => "system"},
        "native_input_id" => native,
        "revision" => revision,
        "content" => content
      })
      when ref in @system_source_refs and
             is_binary(native) and native != "" and is_integer(revision) and revision > 0 and
             is_map(content),
      do: []

  def for_work_input(%{
        "source" => %{"kind" => "schedule", "ref" => "schedule:" <> id},
        "actor" => %{"kind" => "system", "ref" => "schedule"},
        "native_input_id" => native,
        "revision" => revision,
        "content" => content
      })
      when is_binary(native) and native != "" and is_integer(revision) and revision > 0 and
             is_map(content) do
    if Ecto.UUID.cast(id) == {:ok, id}, do: []
  end

  def for_work_input(payload) when is_map(payload) do
    if Enum.any?(
         ~w(source native_input_id source_capabilities occurred_at_source),
         &Map.has_key?(payload, &1)
       ) do
      unexpired_input_sources(payload)
    else
      # Kernel-originated schedules and tasks need not originate in ingress.
      []
    end
  end

  def for_work_input(_), do: nil

  defp unexpired_input_sources(payload) do
    payload |> input_sources() |> unexpired_sources()
  end

  defp unexpired_sources(sources) do
    cutoff = horizon_cutoff()

    if is_list(sources) and Enum.all?(sources, &unexpired?(&1["retained_at"], cutoff)),
      do: sources
  end

  @doc "An authenticated deletion discloses its current receipt and event pointer, never its body."
  def deleted_work_input(
        %Event{
          kind: :input_admitted,
          payload: %{"payload" => %{"event_kind" => "delete"} = input}
        } =
          event,
        current
      )
      when is_boolean(current) do
    case unexpired_sources(matching_input_sources(input)) do
      [_ | _] = sources ->
        %{
          "content" => %{"event_kind" => "delete", "unavailable" => "source_deleted"},
          "current" => current,
          "revision" => input["revision"],
          "source_ref" => event.dedupe_key,
          "source_event_id" => event.id,
          "source_dependencies" => sources
        }

      _ ->
        nil
    end
  end

  def deleted_work_input(_, _), do: nil

  defp exact_deletion_sources(document, event) do
    case deleted_work_input(event, document["current"]) do
      ^document -> document["source_dependencies"]
      _ -> nil
    end
  end

  defp unavailable_work_sources(document, event) do
    if document == withdrawn_work_input(event) do
      []
    else
      exact_deletion_sources(document, event)
    end
  end

  @doc "A withdrawn historical input keeps an audit pointer, never its old prose."
  def withdrawn_work_input(%Event{} = event) do
    %{
      "content" => %{"unavailable" => "source_not_current"},
      "current" => false,
      "source_ref" => event.dedupe_key,
      "source_event_id" => event.id,
      "source_dependencies" => []
    }
  end

  defp work_document_sources(
         %{"source_event_id" => id, "source_dependencies" => _sources} = document
       ) do
    case get_uuid(&Event.Query.by_id/1, id) do
      %Event{kind: :input_admitted} = event ->
        exact_work_sources(document, event, for_work_input(event.payload["payload"]))

      _ ->
        nil
    end
  end

  defp work_document_sources(_), do: nil

  defp exact_work_sources(document, event, nil), do: unavailable_work_sources(document, event)

  defp exact_work_sources(%{"source_dependencies" => sources}, _event, sources)
       when is_list(sources),
       do: sources

  defp exact_work_sources(_, _, _), do: nil

  def document_sources(%{"kind" => "work_input", "input" => document}),
    do: work_document_sources(document)

  # These require the receiving destination and exact producer ownership.
  # KnowledgeSnapshot resolves them together, once per producing session.
  def document_sources(%{"kind" => kind})
      when kind in ~w(episode_record episode_delivery episode_outcome),
      do: nil

  def document_sources(%{"source_ref" => "observation:" <> id} = document) do
    case get_uuid(&ConversationObservation.Query.by_id/1, id) do
      %{note: note, source_dependencies: sources} = source when is_map(note) ->
        # Navigation is a host projection, not the original's custody receipt.
        # Keep exact content/identity checks across reader availability changes.
        if Observations.original_document(source) ==
             Map.drop(document, ["source_read", "thread_ref"]) and
             Map.get(document, "thread_ref", source.thread_ref) == source.thread_ref,
           do: sources

      _ ->
        nil
    end
  end

  def document_sources(%{"source_ref" => "knowledge:" <> id, "version" => version}) do
    with true <- is_integer(version),
         {:ok, ^id} <- Ecto.UUID.cast(id),
         %{source_dependencies: sources} <- Repo.one(knowledge_revision(id, version)) do
      sources
    else
      _ -> nil
    end
  end

  def document_sources(%{"source_ref" => "continuity:" <> id} = document),
    do: summary_sources(get_uuid(&ConversationSummary.Query.by_id/1, id), document)

  def document_sources(%{"source_ref" => "continuity-rollup:" <> _} = document) do
    summary_sources(Repo.one(ConversationRollup.Query.by_ref(document["source_ref"])), document)
  end

  # A new source-backed document must implement custody before it can be shown.
  # Confirmed facts/guidance use their own refs and are not raw-source receipts.
  def document_sources(%{"source_ref" => _}), do: nil
  def document_sources(_), do: []

  defp knowledge_revision(id, version) do
    id
    |> KnowledgeRevision.Query.by_knowledge_id()
    |> KnowledgeRevision.Query.by_version(version)
  end

  # The row `by_id` finds for `id`, or nil when there is none or `id` is no UUID.
  defp get_uuid(by_id, id), do: if(Ecto.UUID.cast(id) == {:ok, id}, do: Repo.one(by_id.(id)))

  defp summary_sources(%{state: state, source_dependencies: [_ | _] = sources}, %{
         "state" => state
       }),
       do: sources

  defp summary_sources(_, _), do: nil

  def valid?(sources, scope), do: match?({:ok, _}, validated_roots(sources, scope))

  @doc "Validate once and return the exact authorized roots for this transaction."
  def validated_roots(sources, scope) when is_list(sources) do
    with {^sources, roots} <- resolve([sources]),
         true <- available_references?(sources),
         true <- future_inputs_absent?(roots, scope) do
      ids = roots |> Enum.map(& &1["observation_id"]) |> Enum.uniq()

      notes =
        ids
        |> ConversationObservation.Query.by_ids()
        |> ConversationObservation.Query.ordered_by_id()
        |> ConversationObservation.Query.lock_for_share()
        |> Repo.all()

      notes = notes |> Observations.authorized_notes(scope) |> Map.new(&{&1.id, &1})
      cutoff = horizon_cutoff()

      if Enum.all?(roots, &valid_receipt?(&1, notes[&1["observation_id"]], scope, cutoff)),
        do: {:ok, roots},
        else: :error
    else
      _ -> :error
    end
  end

  def validated_roots(_, _), do: :error

  defp available_references?(sources) do
    sources
    |> Enum.filter(&reference?/1)
    |> Enum.all?(fn reference ->
      reference["knowledge_id"]
      |> KnowledgeRevision.Query.current_reference(
        reference["generation"],
        reference["through_version"]
      )
      |> Repo.exists?()
    end)
  end

  defp valid_receipt?(_receipt, nil, _scope, _cutoff), do: false

  defp valid_receipt?(_receipt, %{source_result_ref: "source-conflict:" <> _}, _scope, _cutoff),
    do: false

  defp valid_receipt?(receipt, source, scope, cutoff) do
    receipt_matches_source?(receipt, source) and source.workspace_ref == scope.workspace_ref and
      unexpired?(DateTime.to_iso8601(source.updated_at), cutoff) and
      unexpired?(receipt["retained_at"], cutoff)
  end

  defp receipt_matches_source?(receipt, source) do
    source.source_input_id == receipt["source_input_id"] and
      source.revision == receipt["revision"] and
      source.source_fingerprint == receipt["fingerprint"] and
      source.workspace_ref == receipt["workspace_ref"] and
      source.transport == receipt["transport"] and
      source.conversation_ref == receipt["conversation_ref"] and
      source.repository_ref == receipt["repository_ref"]
  end

  @doc """
  What the conversation-memory horizon still keeps: anything retained after
  this moment, by the database clock retention prunes by. Judged by the
  host's, a source the database had expired stayed valid to learning
  (2026-10-04 review). Nil keeps all. Learning, recall and a Work session's
  snapshot all ask here.
  """
  @spec horizon_cutoff() :: DateTime.t() | nil
  def horizon_cutoff do
    case retention_seconds() do
      seconds when is_integer(seconds) and seconds > 0 -> DateTime.add(Repo.now!(), -seconds)
      _unbounded -> nil
    end
  end

  defp unexpired?(at, cutoff) do
    case DateTime.from_iso8601(at || "") do
      {:ok, time, 0} -> is_nil(cutoff) or DateTime.after?(time, cutoff)
      _ -> false
    end
  end

  @doc false
  def retention_seconds do
    settings = Config.get_env(:retention) || %{}

    value =
      if is_list(settings),
        do: Keyword.get(settings, :conversation_memory_seconds),
        else: Map.get(settings, :conversation_memory_seconds)

    if is_integer(value) and value > 0, do: value
  end
end
