defmodule Ryker.Continuity.Recall do
  @moduledoc """
  Recalling summaries and rollups for a destination.

  Automatic recall builds the bounded continuity context a Work submission
  carries; explicit search reads one summary or rollup lane of a memory search
  page. Both recheck visibility and source validity on every hit, so a summary
  is only ever a hint about sources the reader may still see.
  """

  alias Ryker.Continuity
  alias Ryker.Continuity.ConversationRollup
  alias Ryker.Continuity.ConversationSummary
  alias Ryker.Continuity.{Relevance, Scope}
  alias Ryker.Episodes.Episode
  alias Ryker.Knowledge
  alias Ryker.Learning.LearningSources
  alias Ryker.Learning.Observations
  alias Ryker.Learning.SourceDependency
  alias Ryker.Memories.MemorySearchPage
  alias Ryker.Memories.MemorySourceLink
  alias Ryker.Memories.SearchPage
  alias Ryker.Repo

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
        result = recall_context(context, Relevance.request(input_texts), counted?(episode))
        knowledge = Knowledge.context(episode, repository_ref, {:related, input_texts})
        result = if knowledge == [], do: result, else: Map.put(result, "knowledge", knowledge)

        case Observations.related_context(episode, repository_ref, input_texts) do
          [] -> result
          notes -> Map.put(result, "observations", notes)
        end

      {:error, _reason} ->
        empty_context()
    end
  end

  def model_context(_episode, _repository_ref, _input_texts), do: empty_context()

  # A shadow turn reads what a live one would and counts no recall
  # (2026-10-04 review).
  defp counted?(episode), do: episode.execution_mode != :shadow

  defp recall_context(context, request, counted?) do
    case Repo.transaction(fn -> recall_locked(context, request, counted?) end) do
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
      {:ok, context} -> search_visible_page(kind, context, page, counted?(episode))
      _ -> :done
    end
  end

  defp search_visible_page(kind, context, page, counted?) do
    query =
      if kind == :summary,
        do: searchable_summaries_query(context, page.scope),
        else: searchable_rollups_query(context, page.scope)

    # No row lock on the hit: two searches holding one summary FOR SHARE each
    # blocked the other's recall count and PostgreSQL aborted one of them. The
    # count is best effort, and the visibility recheck locks the observations.
    # A search dates a summary or a rollup by the latest message it learned
    # from, not by when maintenance last rewrote it.
    source = SourceDependency.Query.latest_source_at()

    fields =
      if kind == :summary,
        do: ConversationSummary.Query.search_fields(source),
        else: ConversationRollup.Query.search_fields(source)

    query
    |> LearningSources.sourced()
    |> LearningSources.eligible(context)
    |> SearchPage.Query.related_sources(page)
    |> MemorySearchPage.one(page, fields.text, fields.changed, fields.source)
    |> account_search_result(kind, context, counted?)
  end

  defp account_search_result({:ok, item, position}, kind, context, counted?) do
    if continuity_search_candidate_visible?({kind, item}, context) do
      cond do
        not counted? -> :ok
        kind == :summary -> mark_summaries_recalled([item], Repo.now!())
        true -> mark_rollups_recalled([item], Repo.now!())
      end

      {:ok, continuity_search_document({kind, item}), position}
    else
      {:skip, position}
    end
  end

  defp account_search_result(:done, _kind, _context, _counted?), do: :done

  defp recall_locked(context, request, counted?) do
    current =
      context.identity_key
      |> ConversationSummary.Query.by_identity_key()
      |> Repo.one()
      |> learning_visible(context)

    related = related_summaries(context, request)
    rollups = related_rollups(context)
    now = Repo.now!()

    if counted? do
      mark_summaries_recalled(Enum.reject([current | related], &is_nil/1), now)
      mark_rollups_recalled(rollups, now)
    end

    %{
      "current" => if(current, do: summary_document(current)),
      "related" => Enum.map(related, &summary_document/1),
      "rollups" => Enum.map(rollups, &rollup_document/1)
    }
  end

  defp searchable_summaries_query(context, scope) do
    context
    |> ConversationSummary.Query.searchable()
    |> ConversationSummary.Query.within_scope(context, scope)
  end

  defp searchable_rollups_query(context, scope) do
    context
    |> ConversationRollup.Query.for_context()
    |> ConversationRollup.Query.visible_to(context)
    |> ConversationRollup.Query.within_scope(context, scope)
  end

  defp continuity_search_candidate_visible?({:summary, summary}, context),
    do: summary_visible?(summary, context)

  defp continuity_search_candidate_visible?({:rollup, rollup}, context) do
    rollup_visible?(rollup, context) and
      derived_sources_valid?(rollup, context)
  end

  defp continuity_search_document({:summary, summary}),
    do: summary |> summary_document() |> Map.put("kind", "continuity")

  defp continuity_search_document({:rollup, rollup}),
    do: rollup |> rollup_document() |> Map.put("kind", "continuity")

  defp related_summaries(context, request) do
    query =
      context
      |> searchable_summaries_query("workspace")
      |> ConversationSummary.Query.excluding_identity_key(context.identity_key)
      |> ConversationSummary.Query.recently_updated_first()
      |> ConversationSummary.Query.limit_to(@maximum_candidates)
      |> LearningSources.sourced()
      |> LearningSources.eligible(context)

    # Rank small descriptors first. Loading 64 full 8 MiB dependency lists
    # makes a bounded result count a very unbounded application-memory cost.
    query
    |> ConversationSummary.Query.select_descriptors()
    |> Repo.all()
    |> Enum.sort_by(&summary_rank(&1, context, request))
    |> Stream.map(&Repo.one(ConversationSummary.Query.by_id(query, &1.id)))
    |> Stream.reject(&is_nil/1)
    |> Stream.filter(&summary_visible?(&1, context))
    |> Enum.take(@maximum_related)
  end

  defp related_rollups(context) do
    query =
      context
      |> ConversationRollup.Query.for_context()
      |> ConversationRollup.Query.latest_period_first()
      |> ConversationRollup.Query.limit_to(@maximum_candidates)
      |> ConversationRollup.Query.visible_to(context)
      |> LearningSources.sourced()
      |> LearningSources.eligible(context)

    query
    |> ConversationRollup.Query.select_ids()
    |> Repo.all()
    |> Stream.map(&Repo.one(ConversationRollup.Query.by_id(query, &1)))
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

  defp learning_visible(nil, _context), do: nil

  defp learning_visible(item, context),
    do: if(derived_sources_valid?(item, context), do: item)

  defp derived_sources_valid?(item, context) do
    LearningSources.sourced?(item.source_dependencies) and
      LearningSources.valid?(item.source_dependencies, context)
  end

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

  # What the summary shares with the request first (`Ryker.Continuity.Relevance`), then where it
  # was said and how recently, as before.
  defp summary_rank(summary, context, request) do
    relevance = -Relevance.score(state_text(summary.state), request)
    conversation_rank = if summary.conversation_ref == context.conversation_ref, do: 0, else: 1
    repository_rank = if summary.repository_ref == context.repository_ref, do: 0, else: 1
    recent = -DateTime.to_unix(summary.updated_at, :microsecond)
    {relevance, conversation_rank, repository_rank, recent, summary.ref}
  end

  defp state_text(%{} = state),
    do: state |> Map.values() |> Enum.flat_map(&texts/1) |> Enum.join("\n")

  defp state_text(_state), do: ""

  defp texts(value) when is_binary(value), do: [value]
  defp texts(values) when is_list(values), do: Enum.flat_map(values, &texts/1)
  defp texts(%{} = value), do: value |> Map.values() |> Enum.flat_map(&texts/1)
  defp texts(_value), do: []

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

    Repo.update_all(ConversationSummary.Query.by_ids(ids),
      inc: [recall_count: 1],
      set: [last_recalled_at: now]
    )

    Enum.each(summaries, &Continuity.broadcast_continuity_updated(&1.conversation_ref))
  end

  defp mark_rollups_recalled([], _now), do: :ok

  defp mark_rollups_recalled(rollups, now) do
    ids = Enum.map(rollups, & &1.id)

    Repo.update_all(ConversationRollup.Query.by_ids(ids),
      inc: [recall_count: 1],
      set: [last_recalled_at: now]
    )

    Enum.each(rollups, &Continuity.broadcast_continuity_updated(&1.scope_ref))
  end

  defp empty_context, do: %{"current" => nil, "related" => [], "rollups" => []}
end
