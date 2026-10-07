defmodule Ryker.Learning.SourceDependency.Query do
  @moduledoc """
  What every row learned from messages must still have to be shown: its
  `source_dependencies` name sources that are kept, unchanged and readable
  where it is read. Topics, observations, summaries and rollups all compose
  these, by the first binding of the query they are given.
  """
  import Ecto.Query

  @doc "Exclude receiptless derived prose before bounded recall and compaction selection."
  def sourced(queryable) do
    from(item in queryable,
      where:
        fragment(
          "jsonb_typeof(?::jsonb) = 'array' AND ?::jsonb <> '[]'::jsonb",
          item.source_dependencies,
          item.source_dependencies
        )
    )
  end

  @doc """
  Rows whose every source is still eligible in `scope`: the topic revisions
  they cite are kept, and the observations they read are unchanged, not
  forgotten, kept no longer than `retention_seconds` (nil keeps them) and
  readable from `scope`'s conversation. `timestamp_pattern` is the shape of
  a receipt's `retained_at`.
  """
  def eligible(queryable, scope, retention_seconds, timestamp_pattern) do
    # Keep source lookups parameterized per receipt. With stale low row estimates,
    # a flattened outer join materialized the whole source table once per root
    # (100M comparisons for 10k roots). The lateral OFFSET 0 preserves the PK lookup.
    # Pin compact revisions too: joining all historical revisions to their head
    # before matching one descriptor caused 128 head probes for one topic.
    from(item in queryable,
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
            SELECT 1 FROM ryker_learning_roots(?) r
            LEFT JOIN LATERAL (
              SELECT o.* FROM conversation_observations o
              WHERE o.id = CASE WHEN pg_input_is_valid(r->>'observation_id', 'uuid')
                THEN (r->>'observation_id')::uuid ELSE NULL END
              OFFSET 0
            ) o ON true
            WHERE o.id IS NULL OR o.forgotten_at IS NOT NULL
              OR o.source_input_id::text IS DISTINCT FROM r->>'source_input_id'
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
          ^retention_seconds,
          ^retention_seconds,
          ^timestamp_pattern,
          ^retention_seconds,
          ^retention_seconds,
          ^scope.conversation_ref,
          ^(scope.visibility == :public and scope.transport == "slack")
        )
    )
    |> without_future_inputs(scope)
  end

  @doc """
  A background topic can be newer than the Work input boundary. Both queued
  inputs already in the snapshot and arrivals after that snapshot are barred,
  including through an inherited topic or summary root. The host event ledger
  decides, never model-provided timing or a truncated source excerpt.
  """
  def without_future_inputs(queryable, %{input_boundary: {episode_id, sequence, queued}}) do
    from(item in queryable,
      where:
        fragment(
          """
          NOT EXISTS (
            SELECT 1 FROM ryker_learning_roots(?) root
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

  def without_future_inputs(queryable, _scope), do: queryable

  @doc """
  When the latest message a row learned from was said: a summary's or a
  rollup's source clock, not the time maintenance last rewrote it. It reads
  the row through the query's first binding, whichever memory that is.
  """
  def latest_source_at do
    dynamic(
      [item],
      type(
        fragment(
          "(SELECT max(o.occurred_at) FROM ryker_learning_roots(?) r JOIN conversation_observations o ON o.id = CASE WHEN pg_input_is_valid(r->>'observation_id', 'uuid') THEN (r->>'observation_id')::uuid ELSE NULL END)",
          item.source_dependencies
        ),
        :utc_datetime_usec
      )
    )
  end

  @doc "One row holding `roots`, encoded, as `source_dependencies`, for the rules above to judge."
  def roots(encoded_roots),
    do: from(item in fragment("SELECT ?::text AS source_dependencies", ^encoded_roots))
end
