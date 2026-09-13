defmodule Ryker.State.Continuity.Recall do
  @moduledoc """
  Recalling summaries and rollups for a destination.

  Automatic recall builds the bounded continuity context a Work submission
  carries; explicit search reads one summary or rollup lane of a memory search
  page. Both recheck visibility and source validity on every hit, so a summary
  is only ever a hint about sources the reader may still see.
  """

  import Ecto.Query

  alias Ryker.Episodes.Episode
  alias Ryker.Repo

  alias Ryker.State.{
    ConversationRollup,
    ConversationSummary,
    Knowledge,
    LearningSources,
    MemorySearchPage,
    MemorySourceLink,
    Observations
  }

  alias Ryker.State.Continuity.Scope

  @maximum_related 8
  @maximum_rollups 4
  @maximum_candidates 64

  @doc """
  The continuity a model receives for an episode: the destination's current
  summary, related summaries, rollups, and any knowledge and observations that
  bear on the input texts. An unresolvable destination yields empty context.
  """
  @spec model_context(Episode.t(), String.t() | nil, [String.t()]) :: map()
  def model_context(episode, repository_ref, input_texts \\ [])

  def model_context(%Episode{} = episode, repository_ref, input_texts)
      when (is_binary(repository_ref) or is_nil(repository_ref)) and is_list(input_texts) do
    case Scope.destination_context(episode, repository_ref) do
      {:ok, context} ->
        context = LearningSources.with_input_boundary(context, episode)
        result = recall_context(context)
        knowledge = Knowledge.context(episode, repository_ref, {:related, input_texts})
        result = if knowledge == [], do: result, else: Map.put(result, "knowledge", knowledge)

        case Observations.context(episode, repository_ref) do
          [] -> result
          notes -> Map.put(result, "observations", notes)
        end

      {:error, _reason} ->
        empty_context()
    end
  end

  def model_context(_episode, _repository_ref, _input_texts), do: empty_context()

  defp recall_context(context) do
    case Repo.transaction(fn -> recall_locked(context) end) do
      {:ok, result} -> result
      {:error, _reason} -> empty_context()
    end
  end

  @doc """
  The next visible summary or rollup on a memory search page, inside the
  search's transaction. Returns `{:ok, document, position}`, `{:skip, position}`
  for a hit the reader may no longer see, or `:done`.
  """
  @spec search_page(:summary | :rollup, map(), String.t() | nil, map()) ::
          {:ok, map(), term()} | {:skip, term()} | :done
  def search_page(kind, episode, repository_ref, page) when kind in [:summary, :rollup] do
    case Observations.locked_scope(episode, repository_ref) do
      {:ok, context} -> search_visible_page(kind, context, page)
      _ -> :done
    end
  end

  defp search_visible_page(kind, context, page) do
    query =
      if kind == :summary,
        do: searchable_summaries_query(context, page.scope),
        else: searchable_rollups_query(context, page.scope)

    # No row lock on the hit: two searches holding one summary FOR SHARE each
    # blocked the other's recall count and PostgreSQL aborted one of them. The
    # count is best effort, and the visibility recheck locks the observations.
    query
    |> LearningSources.sourced()
    |> LearningSources.eligible(context)
    |> MemorySearchPage.related_sources(page)
    |> MemorySearchPage.one(
      page,
      dynamic([item], item.state),
      dynamic([item], item.updated_at),
      search_source_clock()
    )
    |> account_search_result(kind, context)
  end

  defp search_source_clock do
    # This clock is the latest backing message, not the maintenance job time.
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

  defp account_search_result({:ok, item, position}, kind, context) do
    if continuity_search_candidate_visible?({kind, item}, context) do
      if kind == :summary,
        do: mark_summaries_recalled([item], Repo.now!()),
        else: mark_rollups_recalled([item], Repo.now!())

      {:ok, continuity_search_document({kind, item}), position}
    else
      {:skip, position}
    end
  end

  defp account_search_result(:done, _kind, _context), do: :done

  defp recall_locked(context) do
    current =
      Repo.one(
        from(summary in ConversationSummary, where: summary.identity_key == ^context.identity_key)
      )
      |> learning_visible(context)

    related = related_summaries(context)
    rollups = related_rollups(context)
    now = Repo.now!()

    mark_summaries_recalled(Enum.reject([current | related], &is_nil/1), now)
    mark_rollups_recalled(rollups, now)

    %{
      "current" => if(current, do: summary_document(current)),
      "related" => Enum.map(related, &summary_document/1),
      "rollups" => Enum.map(rollups, &rollup_document/1)
    }
  end

  defp searchable_summaries_query(context, scope) do
    from(summary in ConversationSummary,
      where: summary.workspace_ref == ^context.workspace_ref,
      where: ^Observations.visible_conversations(context),
      where: summary.conversation_ref == ^context.conversation_ref or summary.transport == "slack"
    )
    |> summaries_within_scope(context, scope)
  end

  defp summaries_within_scope(query, context, "current_channel"),
    do: from(summary in query, where: summary.conversation_ref == ^context.conversation_ref)

  defp summaries_within_scope(query, %{repository_ref: repository_ref}, "repository")
       when is_binary(repository_ref),
       do: from(summary in query, where: summary.repository_ref == ^repository_ref)

  defp summaries_within_scope(query, _context, "workspace"), do: query
  defp summaries_within_scope(query, _context, _scope), do: from(summary in query, where: false)

  defp searchable_rollups_query(context, scope) do
    context
    |> rollups_for_context_query()
    |> rollups_visible_query(context)
    |> rollups_within_scope(context, scope)
  end

  defp rollups_within_scope(query, context, "current_channel"),
    do:
      from(rollup in query,
        where:
          rollup.scope_kind == :conversation and rollup.scope_ref == ^context.conversation_ref
      )

  defp rollups_within_scope(query, %{repository_ref: repository_ref}, "repository")
       when is_binary(repository_ref),
       do: from(rollup in query, where: rollup.repository_ref == ^repository_ref)

  defp rollups_within_scope(query, _context, "workspace"), do: query
  defp rollups_within_scope(query, _context, _scope), do: from(rollup in query, where: false)

  defp rollups_visible_query(
         query,
         %{visibility: :public, repository_ref: repository_ref} = context
       )
       when is_binary(repository_ref) do
    public_sources = public_rollup_sources_query()

    visible =
      dynamic(
        [rollup],
        (rollup.scope_kind == :conversation and rollup.scope_ref == ^context.conversation_ref) or
          (rollup.scope_kind == :repository and rollup.repository_ref == ^repository_ref and
             rollup.visibility == :public and ^public_sources)
      )

    from(rollup in query, where: ^visible)
  end

  defp rollups_visible_query(query, context) do
    from(rollup in query,
      where: rollup.scope_kind == :conversation and rollup.scope_ref == ^context.conversation_ref
    )
  end

  defp public_rollup_sources_query do
    dynamic(
      [rollup],
      fragment(
        """
        NOT EXISTS (
          SELECT 1 FROM jsonb_array_elements(COALESCE(?::jsonb, '[]'::jsonb)) source_scope
          LEFT JOIN slack_channel_memberships membership
            ON membership.workspace_ref = source_scope->>'workspace_ref'
           AND membership.channel_ref = source_scope->>'channel_ref'
          WHERE source_scope->>'transport' IS DISTINCT FROM 'slack'
             OR membership.workspace_ref IS NULL
             OR membership.status IS DISTINCT FROM 'joined'
             OR membership.private IS DISTINCT FROM false
             OR membership.external_shared IS DISTINCT FROM false
        )
        """,
        rollup.source_scopes
      )
    )
  end

  defp continuity_search_candidate_visible?({:summary, summary}, context),
    do: summary_visible?(summary, context)

  defp continuity_search_candidate_visible?({:rollup, rollup}, context),
    do:
      rollup_visible?(rollup, context) and
        derived_sources_valid?(rollup, context)

  defp continuity_search_document({:summary, summary}),
    do: summary |> summary_document() |> Map.put("kind", "continuity")

  defp continuity_search_document({:rollup, rollup}),
    do: rollup |> rollup_document() |> Map.put("kind", "continuity")

  defp related_summaries(context) do
    query =
      context
      |> searchable_summaries_query("workspace")
      |> where([summary], summary.identity_key != ^context.identity_key)
      |> order_by([summary], desc: summary.updated_at, desc: summary.id)
      |> limit(@maximum_candidates)
      |> LearningSources.sourced()
      |> LearningSources.eligible(context)

    # Rank small descriptors first. Loading 64 full 8 MiB dependency lists
    # makes a bounded result count a very unbounded application-memory cost.
    Repo.all(
      from(summary in query,
        select: map(summary, [:id, :conversation_ref, :repository_ref, :updated_at, :ref])
      )
    )
    |> Enum.sort_by(&summary_rank(&1, context))
    |> Stream.map(fn item -> Repo.one(from(summary in query, where: summary.id == ^item.id)) end)
    |> Stream.reject(&is_nil/1)
    |> Stream.filter(&summary_visible?(&1, context))
    |> Enum.take(@maximum_related)
  end

  defp related_rollups(context) do
    query =
      context
      |> related_rollups_query()
      |> rollups_visible_query(context)
      |> LearningSources.sourced()
      |> LearningSources.eligible(context)

    Repo.all(from(rollup in query, select: rollup.id))
    |> Stream.map(fn id -> Repo.one(from(rollup in query, where: rollup.id == ^id)) end)
    |> Stream.reject(&is_nil/1)
    |> Stream.filter(&(rollup_visible?(&1, context) and derived_sources_valid?(&1, context)))
    |> Enum.take(@maximum_rollups)
  end

  defp summary_visible?(summary, context) do
    (summary.conversation_ref == context.conversation_ref or
       (context.visibility == :public and summary.visibility == :public and
          Scope.public_source_visible?(summary))) and
      derived_sources_valid?(summary, context)
  end

  defp related_rollups_query(context) do
    context
    |> rollups_for_context_query()
    |> order_by([rollup], desc: rollup.period_end, desc: rollup.id)
    |> limit(@maximum_candidates)
  end

  defp rollups_for_context_query(%{repository_ref: repository_ref} = context)
       when is_binary(repository_ref) do
    from(rollup in ConversationRollup,
      where:
        rollup.workspace_ref == ^context.workspace_ref and
          rollup.expires_at > fragment("clock_timestamp()") and
          ((rollup.scope_kind == :conversation and
              rollup.scope_ref == ^context.conversation_ref) or
             (rollup.scope_kind == :repository and rollup.repository_ref == ^repository_ref))
    )
  end

  defp rollups_for_context_query(context) do
    from(rollup in ConversationRollup,
      where:
        rollup.workspace_ref == ^context.workspace_ref and
          rollup.expires_at > fragment("clock_timestamp()") and
          rollup.scope_kind == :conversation and
          rollup.scope_ref == ^context.conversation_ref
    )
  end

  defp learning_visible(nil, _context), do: nil

  defp learning_visible(item, context),
    do: if(derived_sources_valid?(item, context), do: item)

  defp derived_sources_valid?(item, context),
    do:
      LearningSources.sourced?(item.source_dependencies) and
        LearningSources.valid?(item.source_dependencies, context)

  defp rollup_visible?(
         %ConversationRollup{scope_kind: :conversation, scope_ref: scope_ref},
         context
       ),
       do: scope_ref == context.conversation_ref

  defp rollup_visible?(%ConversationRollup{scope_kind: :repository} = rollup, context) do
    context.visibility == :public and is_binary(context.repository_ref) and
      rollup.repository_ref == context.repository_ref and rollup.visibility == :public and
      Enum.all?(rollup.source_scopes, &public_rollup_source_visible?/1)
  end

  defp public_rollup_source_visible?(%{
         "channel_ref" => channel_ref,
         "transport" => "slack",
         "workspace_ref" => workspace_ref
       }) do
    Scope.public_source_visible?(%ConversationSummary{
      conversation_ref: "slack:#{workspace_ref}:#{channel_ref}",
      transport: "slack",
      workspace_ref: "slack:#{workspace_ref}"
    })
  end

  defp public_rollup_source_visible?(_scope), do: false

  defp summary_rank(summary, context) do
    conversation_rank = if summary.conversation_ref == context.conversation_ref, do: 0, else: 1
    repository_rank = if summary.repository_ref == context.repository_ref, do: 0, else: 1
    recent = -DateTime.to_unix(summary.updated_at, :microsecond)
    {conversation_rank, repository_rank, recent, summary.ref}
  end

  defp summary_document(summary) do
    %{
      "transport" => summary.transport,
      "workspace_ref" => summary.workspace_ref,
      "conversation_ref" => summary.conversation_ref,
      "thread_ref" => summary.thread_ref,
      "source_message_ref" => summary.source_message_ref,
      "repository_ref" => summary.repository_ref,
      "source_ref" => summary.ref,
      "source_reads" => MemorySourceLink.sources(summary.source_dependencies),
      "state" => summary.state,
      "coverage" => %{"basis" => "derived_handover", "status" => "partial"},
      "updated_at" => DateTime.to_iso8601(summary.updated_at)
    }
  end

  defp rollup_document(rollup) do
    %{
      "workspace_ref" => rollup.workspace_ref,
      "scope_kind" => Atom.to_string(rollup.scope_kind),
      "scope_ref" => rollup.scope_ref,
      "period_end" => DateTime.to_iso8601(rollup.period_end),
      "period_start" => DateTime.to_iso8601(rollup.period_start),
      "updated_at" => DateTime.to_iso8601(rollup.updated_at),
      "expires_at" => DateTime.to_iso8601(rollup.expires_at),
      "repository_ref" => rollup.repository_ref,
      "source_count" => rollup.source_count,
      "source_ref" => rollup.ref,
      "source_refs" => rollup.source_refs,
      "source_reads" => MemorySourceLink.sources(rollup.source_dependencies),
      "coverage" => %{"basis" => "compacted_continuity", "status" => "partial"},
      "state" => rollup.state
    }
  end

  defp mark_summaries_recalled([], _now), do: :ok

  defp mark_summaries_recalled(summaries, now) do
    ids = Enum.map(summaries, & &1.id)

    Repo.update_all(from(summary in ConversationSummary, where: summary.id in ^ids),
      inc: [recall_count: 1],
      set: [last_recalled_at: now]
    )

    :ok
  end

  defp mark_rollups_recalled([], _now), do: :ok

  defp mark_rollups_recalled(rollups, now) do
    ids = Enum.map(rollups, & &1.id)

    Repo.update_all(from(rollup in ConversationRollup, where: rollup.id in ^ids),
      inc: [recall_count: 1],
      set: [last_recalled_at: now]
    )

    :ok
  end

  defp empty_context, do: %{"current" => nil, "related" => [], "rollups" => []}
end
