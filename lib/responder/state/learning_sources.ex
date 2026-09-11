defmodule Responder.State.LearningSources do
  @moduledoc "Bounded, host-owned source receipts carried across derived conversation memory."
  import Ecto.Query
  alias Responder.{CanonicalJSON, Repo}
  alias Responder.Episodes.Event
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Publication.LifecycleEvent

  alias Responder.State.{
    ConversationKnowledge,
    ConversationObservation,
    ConversationRollup,
    ConversationSummary,
    KnowledgeRevision,
    Observations
  }

  @maximum_sources 10_000
  @maximum_bytes 8 * 1_024 * 1_024
  @receipt_fields ~w(observation_id source_input_id revision fingerprint transport workspace_ref conversation_ref repository_ref visibility retained_at)
  @utc_timestamp_pattern ~S/\A[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])[T ]([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]([.,][0-9]+)?(Z|[+]00(:?00)?|-00(00)?)\Z/

  # PostgreSQL also accepts relative times, infinity and non-UTC offsets. The
  # SQL prefilter must reject those before a malformed receipt spends a slot.
  # Calendar validity is still checked before casting; the locked host check
  # remains authoritative for the complete receipt.
  @doc false
  def utc_timestamp_pattern, do: @utc_timestamp_pattern

  @doc false
  def with_input_boundary(scope, %Responder.Episodes.Episode{id: id} = episode)
      when is_binary(id),
      do:
        Map.put(
          scope,
          :input_boundary,
          {episode.id, episode.next_sequence, episode.queued_input_refs}
        )

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
            FROM responder_learning_roots($1) r
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

  @doc "Derived prose requires at least one source; source-free host tasks do not."
  def sourced?([_ | _]), do: true
  def sourced?(_), do: false

  @doc "Exclude receiptless derived prose before bounded recall and compaction selection."
  def sourced(query) do
    from(item in query,
      where:
        fragment(
          "jsonb_typeof(?::jsonb) = 'array' AND ?::jsonb <> '[]'::jsonb",
          item.source_dependencies,
          item.source_dependencies
        )
    )
  end

  @doc "Filter inherited source eligibility before recall limits; locked validation still follows."
  def eligible(query, scope) do
    seconds = retention_seconds()

    # Keep source lookups parameterized per receipt. With stale low row estimates,
    # a flattened outer join materialized the whole source table once per root
    # (100M comparisons for 10k roots). The lateral OFFSET 0 preserves the PK lookup.
    # Pin compact revisions too: joining all historical revisions to their head
    # before matching one descriptor caused 128 head probes for one topic.
    from(item in query,
      where: not is_nil(item.source_dependencies),
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM jsonb_array_elements(CASE
              WHEN pg_input_is_valid(?, 'jsonb') THEN CASE WHEN jsonb_typeof(?::jsonb) = 'array'
                THEN ?::jsonb ELSE '[null]'::jsonb END ELSE '[null]'::jsonb END) d
            LEFT JOIN LATERAL (
              SELECT v.knowledge_id, v.source_generation, v.state
              FROM conversation_knowledge_revisions v
              WHERE v.knowledge_id = CASE WHEN pg_input_is_valid(d->>'knowledge_id', 'uuid')
                  THEN (d->>'knowledge_id')::uuid ELSE NULL END
                AND v.source_generation = CASE WHEN pg_input_is_valid(d->>'generation', 'bigint')
                  THEN (d->>'generation')::bigint ELSE NULL END
                AND v.version = CASE WHEN pg_input_is_valid(d->>'through_version', 'bigint')
                  THEN (d->>'through_version')::bigint ELSE NULL END
              OFFSET 0
            ) v ON true
            LEFT JOIN conversation_knowledge head
              ON head.id = v.knowledge_id AND head.source_generation = v.source_generation
            WHERE jsonb_exists(d, 'knowledge_id') AND
              (head.id IS NULL OR v.knowledge_id IS NULL OR v.state::jsonb = '{"retention":"pruned"}'::jsonb)
          )
          """,
          item.source_dependencies,
          item.source_dependencies,
          item.source_dependencies
        ),
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM responder_learning_roots(?) r
            LEFT JOIN LATERAL (
              SELECT o.* FROM conversation_observations o
              WHERE o.id = CASE WHEN pg_input_is_valid(r->>'observation_id', 'uuid')
                THEN (r->>'observation_id')::uuid ELSE NULL END
              OFFSET 0
            ) o ON true
            WHERE o.id IS NULL OR o.source_input_id::text IS DISTINCT FROM r->>'source_input_id'
              OR o.revision::text IS DISTINCT FROM r->>'revision'
              OR o.source_fingerprint IS DISTINCT FROM r->>'fingerprint'
              OR o.workspace_ref IS DISTINCT FROM ?
              OR o.workspace_ref IS DISTINCT FROM r->>'workspace_ref'
              OR o.transport IS DISTINCT FROM r->>'transport'
              OR o.conversation_ref IS DISTINCT FROM r->>'conversation_ref'
              OR o.repository_ref IS DISTINCT FROM r->>'repository_ref'
              OR (?::bigint IS NOT NULL AND o.updated_at <= clock_timestamp() - (? * interval '1 second'))
              OR CASE WHEN r->>'retained_at' ~ ?
                AND pg_input_is_valid(replace(r->>'retained_at', ',', '.'), 'timestamptz') THEN
                (?::bigint IS NOT NULL AND replace(r->>'retained_at', ',', '.')::timestamptz <= clock_timestamp() - (? * interval '1 second'))
                ELSE true END
              OR NOT (
                o.conversation_ref = ? OR (? AND o.visibility = 'public' AND EXISTS (
                  SELECT 1 FROM slack_channel_memberships m
                  WHERE 'slack:' || m.workspace_ref || ':' || m.channel_ref = o.conversation_ref
                    AND m.status = 'joined' AND NOT m.private AND NOT m.external_shared
                ))
              )
          )
          """,
          item.source_dependencies,
          ^scope.workspace_ref,
          ^seconds,
          ^seconds,
          ^@utc_timestamp_pattern,
          ^seconds,
          ^seconds,
          ^scope.conversation_ref,
          ^(scope.visibility == :public and scope.transport == "slack")
        )
    )
    |> without_future_inputs(scope)
  end

  # A background topic can be newer than the Work input boundary. Both queued
  # inputs already in the snapshot and arrivals after that snapshot are barred,
  # including through an inherited topic/summary root. Query the host event
  # ledger, never model-provided timing or a truncated source excerpt.
  defp without_future_inputs(query, %{input_boundary: {episode_id, sequence, queued}}) do
    from(item in query,
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM responder_learning_roots(?) root
            JOIN ingress_inbox_entries i ON i.id = CASE
              WHEN pg_input_is_valid(root->>'source_input_id', 'uuid')
              THEN (root->>'source_input_id')::uuid ELSE NULL END
            JOIN episode_kernel_events e ON e.episode_id = i.episode_id AND e.kind = 'input_admitted'
              AND coalesce(e.payload::jsonb #>> '{payload,native_input_id}',
                e.payload::jsonb ->> 'native_input_id') = i.native_input_id
              AND e.payload::jsonb ->> 'revision' = i.revision::text
            WHERE i.episode_id = ?::uuid AND (e.sequence >= ? OR e.dedupe_key = ANY(?::text[]))
          )
          """,
          item.source_dependencies,
          ^Ecto.UUID.dump!(episode_id),
          ^sequence,
          ^queued
        )
    )
  end

  defp without_future_inputs(query, _scope), do: query

  defp future_inputs_absent?(roots, %{input_boundary: _} = scope) do
    from(item in fragment("SELECT ?::text AS source_dependencies", ^CanonicalJSON.encode!(roots)))
    |> without_future_inputs(scope)
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
      text?(receipt["fingerprint"], 64) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, receipt["fingerprint"]) and
      scope_shape?(receipt) and timestamp?(receipt["retained_at"])
  end

  defp valid_shape?(_), do: false

  defp scope_shape?(receipt) do
    Enum.all?(~w(transport workspace_ref conversation_ref), &text?(receipt[&1], 1024)) and
      (is_nil(receipt["repository_ref"]) or text?(receipt["repository_ref"], 1024)) and
      receipt["visibility"] in ~w(public private direct conversation)
  end

  defp text?(value, limit),
    do: is_binary(value) and String.valid?(value) and byte_size(value) in 1..limit

  defp timestamp?(value) when is_binary(value),
    do: match?({:ok, _, 0}, DateTime.from_iso8601(value))

  defp timestamp?(_), do: false

  def for_entry(entry) do
    identity = Observations.source_identity(entry)
    source = Repo.one(from(o in ConversationObservation, where: o.identity_key == ^identity))

    case source do
      %{source_result_ref: "source-conflict:" <> _} ->
        nil

      %{source_input_id: id, revision: revision}
      when id == entry.id and revision == entry.revision ->
        [receipt(source)]

      _ ->
        nil
    end
  end

  def for_source(source) do
    existing =
      Repo.one(from(o in ConversationObservation, where: o.identity_key == ^source.identity_key))

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

    with %{} = source <-
           Repo.one(from(o in ConversationObservation, where: o.identity_key == ^identity)),
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
    case get_uuid(LifecycleEvent, id) do
      %LifecycleEvent{kind: "review_feedback", observation: observation} ->
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
    case Repo.get(Entry, source.source_input_id) do
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
      when ref in ["responder", "emisar", "publication-lifecycle"] and
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
    if is_list(sources) and Enum.all?(sources, &unexpired?(&1["retained_at"])),
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
    case input |> matching_input_sources() |> unexpired_sources() do
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
    case get_uuid(Event, id) do
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
    case get_uuid(ConversationObservation, id) do
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
    case if(Ecto.UUID.cast(id) == {:ok, id} and is_integer(version),
           do: Repo.get_by(KnowledgeRevision, knowledge_id: id, version: version)
         ) do
      %{source_dependencies: sources} -> sources
      _ -> nil
    end
  end

  def document_sources(%{"source_ref" => "continuity:" <> id} = document),
    do: summary_sources(get_uuid(ConversationSummary, id), document)

  def document_sources(%{"source_ref" => "continuity-rollup:" <> _} = document),
    do: summary_sources(Repo.get_by(ConversationRollup, ref: document["source_ref"]), document)

  # A new source-backed document must implement custody before it can be shown.
  # Confirmed facts/guidance use their own refs and are not raw-source receipts.
  def document_sources(%{"source_ref" => _}), do: nil
  def document_sources(_), do: []

  defp get_uuid(schema, id), do: if(Ecto.UUID.cast(id) == {:ok, id}, do: Repo.get(schema, id))

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
        Repo.all(
          from(o in ConversationObservation,
            where: o.id in ^ids,
            order_by: [asc: o.id],
            lock: "FOR SHARE"
          )
        )

      notes = notes |> Observations.authorized_notes(scope) |> Map.new(&{&1.id, &1})

      if Enum.all?(roots, &valid_receipt?(&1, notes[&1["observation_id"]], scope)),
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
      Repo.exists?(
        from(v in KnowledgeRevision,
          join: head in ConversationKnowledge,
          on: head.id == v.knowledge_id and head.source_generation == v.source_generation,
          where:
            v.knowledge_id == ^reference["knowledge_id"] and
              v.source_generation == ^reference["generation"] and
              v.version == ^reference["through_version"],
          where: fragment(~s(?::jsonb <> '{"retention":"pruned"}'::jsonb), v.state)
        )
      )
    end)
  end

  defp valid_receipt?(_receipt, nil, _scope), do: false

  defp valid_receipt?(_receipt, %{source_result_ref: "source-conflict:" <> _}, _scope),
    do: false

  defp valid_receipt?(receipt, source, scope) do
    receipt_matches_source?(receipt, source) and source.workspace_ref == scope.workspace_ref and
      unexpired?(DateTime.to_iso8601(source.updated_at)) and unexpired?(receipt["retained_at"])
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

  defp unexpired?(at) do
    seconds = retention_seconds()

    case DateTime.from_iso8601(at || "") do
      {:ok, time, 0} ->
        not is_integer(seconds) or seconds <= 0 or
          DateTime.after?(time, DateTime.add(DateTime.utc_now(), -seconds))

      _ ->
        false
    end
  end

  @doc false
  def retention_seconds do
    settings = Application.get_env(:responder, :retention) || %{}

    value =
      if is_list(settings),
        do: Keyword.get(settings, :conversation_memory_seconds),
        else: Map.get(settings, :conversation_memory_seconds)

    if is_integer(value) and value > 0, do: value
  end
end
