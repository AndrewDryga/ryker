defmodule Ryker.State.Continuity.Compaction do
  @moduledoc """
  Retention maintenance for continuity: folding aged summaries into weekly
  rollups and removing everything a deleted Slack channel left behind.

  A rollup keeps the merged state, the refs and scopes of the summaries it
  absorbed, and their source receipts. It never outlives the retention horizon
  of the sources it summarizes.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership

  alias Ryker.State.{
    ConversationKnowledge,
    ConversationObservation,
    ConversationRollup,
    ConversationSummary,
    ConversationSummaryDraft,
    ConversationSummaryState,
    LearningSources
  }

  alias Ryker.State.Continuity.Scope

  @maximum_compaction 100
  @maximum_rollup_source_refs 500
  @maximum_rollup_source_scopes 10_000
  @maximum_rollup_source_ref_bytes 32 * 1_024
  @maximum_rollup_source_scope_bytes 8 * 1_024 * 1_024
  @maximum_state_bytes 32 * 1_024

  @doc """
  Fold one bounded window of summaries older than `summary_age_seconds` into
  their rollups, which expire `rollup_retention_seconds` after their newest
  source. Returns the number of summaries compacted.
  """
  @spec compact_in_transaction(pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def compact_in_transaction(summary_age_seconds, rollup_retention_seconds)
      when is_integer(summary_age_seconds) and summary_age_seconds > 0 and
             is_integer(rollup_retention_seconds) and rollup_retention_seconds > 0 do
    if Repo.in_transaction?() do
      compact_locked(summary_age_seconds, rollup_retention_seconds)
    else
      {:error, :conversation_summary_transaction_required}
    end
  end

  def compact_in_transaction(_summary_age_seconds, _rollup_retention_seconds),
    do: {:error, :invalid_conversation_summary_retention}

  @doc """
  Remove the summaries, drafts, rollups, knowledge and observations of a Slack
  channel the workspace deleted.
  """
  @spec delete_slack_channel_in_transaction(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_slack_channel_in_transaction(workspace_ref, channel_ref)
      when is_binary(workspace_ref) and is_binary(channel_ref) do
    if Repo.in_transaction?() do
      delete_slack_channel_locked(workspace_ref, channel_ref)
    else
      {:error, :conversation_summary_transaction_required}
    end
  end

  def delete_slack_channel_in_transaction(_workspace_ref, _channel_ref),
    do: {:error, :conversation_summary_destination}

  defp compact_locked(summary_age_seconds, rollup_retention_seconds) do
    before = DateTime.add(Repo.now!(), -summary_age_seconds, :second)

    from(summary in ConversationSummary,
      as: :summary,
      where: summary.updated_at < ^before and summary.state != ^%{"retention" => "pruned"},
      where:
        is_nil(summary.compaction_retry_at) or
          summary.compaction_retry_at <= fragment("clock_timestamp()"),
      order_by: [asc: summary.updated_at, asc: summary.id],
      limit: @maximum_compaction,
      lock: "FOR UPDATE"
    )
    |> LearningSources.sourced()
    |> without_unsourced_rollup()
    |> Repo.all()
    |> Enum.group_by(&rollup_identity/1)
    |> Enum.sort_by(fn {identity, _items} -> identity end)
    |> compact_groups(rollup_retention_seconds)
  end

  defp compact_groups(groups, rollup_retention_seconds) do
    Enum.reduce_while(groups, {:ok, 0}, fn {_identity, sources}, {:ok, count} ->
      case compact_group(sources, rollup_retention_seconds) do
        :ok -> {:cont, {:ok, count + length(sources)}}
        :skipped -> {:cont, {:ok, count}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp without_unsourced_rollup(query) do
    # Match rollup_identity/1 before LIMIT so preserved history cannot monopolize
    # every maintenance pass. The locked group check remains authoritative.
    repository_scope = repository_rollup_scope_query()

    matching_scope =
      dynamic(
        [rollup],
        (^repository_scope and rollup.scope_kind == :repository and
           rollup.scope_ref == parent_as(:summary).repository_ref) or
          (not (^repository_scope) and rollup.scope_kind == :conversation and
             rollup.scope_ref == parent_as(:summary).conversation_ref)
      )

    blocked =
      from(rollup in ConversationRollup,
        where: rollup.workspace_ref == parent_as(:summary).workspace_ref,
        where: rollup.state != ^%{"retention" => "pruned"},
        where:
          fragment(
            "CASE WHEN jsonb_typeof(?::jsonb) = 'array' THEN ?::jsonb = '[]'::jsonb ELSE true END",
            rollup.source_dependencies,
            rollup.source_dependencies
          ),
        where:
          rollup.period_start <= parent_as(:summary).updated_at and
            fragment(
              "? < ? + interval '7 days'",
              parent_as(:summary).updated_at,
              rollup.period_start
            ),
        where: ^matching_scope
      )

    from(summary in query, where: not exists(subquery(blocked)))
  end

  defp repository_rollup_scope_query do
    memberships =
      from(membership in ChannelMembership,
        # The host splits a conversation into exactly transport/workspace/channel.
        # Colons can belong to the channel suffix, never the workspace component.
        where: fragment("position(':' in ?) = 0", membership.workspace_ref),
        where:
          fragment(
            "? = 'slack:' || ?",
            parent_as(:summary).workspace_ref,
            membership.workspace_ref
          ),
        where:
          fragment(
            "? = 'slack:' || ? || ':' || ?",
            parent_as(:summary).conversation_ref,
            membership.workspace_ref,
            membership.channel_ref
          ),
        where:
          membership.status == :joined and not membership.private and
            not membership.external_shared
      )

    dynamic(
      parent_as(:summary).transport == "slack" and parent_as(:summary).visibility == :public and
        not is_nil(parent_as(:summary).repository_ref) and exists(subquery(memberships))
    )
  end

  defp delete_slack_channel_locked(workspace_ref, channel_ref) do
    conversation_ref = "slack:#{workspace_ref}:#{channel_ref}"
    scoped_workspace_ref = "slack:#{workspace_ref}"

    delete_channel_summaries(scoped_workspace_ref, conversation_ref)
    delete_channel_drafts(conversation_ref)
    delete_channel_rollups(scoped_workspace_ref, conversation_ref, workspace_ref, channel_ref)

    Repo.delete_all(
      from(item in ConversationKnowledge,
        where:
          item.workspace_ref == ^scoped_workspace_ref and
            item.conversation_ref == ^conversation_ref
      )
    )

    Repo.delete_all(
      from(note in ConversationObservation,
        where:
          note.workspace_ref == ^scoped_workspace_ref and
            note.conversation_ref == ^conversation_ref
      )
    )

    :ok
  end

  defp delete_channel_summaries(workspace_ref, conversation_ref) do
    Repo.delete_all(
      from(summary in ConversationSummary,
        where:
          summary.workspace_ref == ^workspace_ref and
            summary.conversation_ref == ^conversation_ref
      )
    )
  end

  defp delete_channel_drafts(conversation_ref) do
    Repo.all(
      from(draft in ConversationSummaryDraft,
        join: episode in Episode,
        on: episode.id == draft.episode_id,
        where:
          episode.destination_transport == "slack" and
            episode.destination_conversation_ref == ^conversation_ref,
        select: draft.id
      )
    )
    |> delete_drafts()
  end

  defp delete_drafts([]), do: :ok

  defp delete_drafts(draft_ids) do
    Repo.delete_all(from(draft in ConversationSummaryDraft, where: draft.id in ^draft_ids))
  end

  defp delete_channel_rollups(workspace_ref, conversation_ref, slack_workspace_ref, channel_ref) do
    Repo.all(
      from(rollup in ConversationRollup,
        where: rollup.workspace_ref == ^workspace_ref,
        lock: "FOR UPDATE"
      )
    )
    |> Enum.filter(&rollup_uses_channel?(&1, conversation_ref, slack_workspace_ref, channel_ref))
    |> Enum.map(& &1.id)
    |> delete_rollups()
  end

  defp rollup_uses_channel?(rollup, conversation_ref, workspace_ref, channel_ref) do
    rollup.scope_ref == conversation_ref or
      Enum.any?(rollup.source_scopes, &slack_source?(&1, workspace_ref, channel_ref))
  end

  defp slack_source?(source, workspace_ref, channel_ref) do
    source["transport"] == "slack" and source["workspace_ref"] == workspace_ref and
      source["channel_ref"] == channel_ref
  end

  defp delete_rollups([]), do: :ok

  defp delete_rollups(rollup_ids) do
    Repo.delete_all(from(rollup in ConversationRollup, where: rollup.id in ^rollup_ids))
  end

  defp rollup_identity(summary) do
    period_start = beginning_of_week(summary.updated_at)

    if summary.visibility == :public and is_binary(summary.repository_ref) and
         Scope.public_source_visible?(summary) do
      {summary.workspace_ref, :repository, summary.repository_ref, period_start}
    else
      {summary.workspace_ref, :conversation, summary.conversation_ref, period_start}
    end
  end

  defp compact_group([first | _rest] = sources, retention_seconds) do
    identity = rollup_identity(first)
    {workspace_ref, scope_kind, scope_ref, period_start} = identity

    existing = locked_rollup(workspace_ref, scope_kind, scope_ref, period_start)
    retained = if existing && existing.state != %{"retention" => "pruned"}, do: existing

    if retained && not LearningSources.sourced?(retained.source_dependencies) do
      # Preserve historical prose; a later sourced summary cannot retroactively attribute it.
      :skipped
    else
      compact_sourced_group(sources, retained, existing, retention_seconds, identity)
    end
  end

  defp compact_sourced_group(
         [first | _rest] = sources,
         retained,
         existing,
         retention_seconds,
         identity
       ) do
    attributes =
      rollup_attributes(
        first,
        sources,
        retained,
        retention_seconds,
        identity
      )

    complete_compaction(existing, sources, attributes)
  end

  defp locked_rollup(workspace_ref, scope_kind, scope_ref, period_start) do
    Repo.one(
      from(rollup in ConversationRollup,
        where:
          rollup.workspace_ref == ^workspace_ref and rollup.scope_kind == ^scope_kind and
            rollup.scope_ref == ^scope_ref and rollup.period_start == ^period_start,
        lock: "FOR UPDATE"
      )
    )
  end

  defp rollup_attributes(
         first,
         sources,
         existing,
         retention_seconds,
         {workspace_ref, scope_kind, scope_ref, period_start}
       ) do
    states = Enum.map(sources, &{&1.updated_at, &1.state}) ++ existing_states(existing)
    period_end = sources |> Enum.map(& &1.updated_at) |> latest_period_end(existing)
    state = merge_states(states)
    rollup = existing_rollup(existing)
    new_refs = Enum.map(sources, & &1.ref)

    %{
      expires_at: DateTime.add(period_end, retention_seconds, :second),
      period_end: period_end,
      period_start: period_start,
      repository_ref: rollup_repository_ref(scope_kind, scope_ref, first),
      scope_kind: scope_kind,
      scope_ref: scope_ref,
      source_count: rollup.source_count + Enum.count(new_refs, &(&1 not in rollup.source_refs)),
      source_refs: bounded_source_refs(rollup.source_refs, new_refs),
      source_scopes: merged_source_scopes(rollup.source_scopes, sources),
      source_dependencies:
        LearningSources.merge([
          rollup.source_dependencies | Enum.map(sources, & &1.source_dependencies)
        ]),
      state: state,
      state_fingerprint: CanonicalJSON.digest(state),
      visibility: rollup_visibility(scope_kind, first),
      workspace_ref: workspace_ref
    }
  end

  # A group without a rollup yet merges into an empty one. Its state and period
  # keep their own nil guards: an absent rollup contributes no state and no
  # period end, and no placeholder can stand in for either.
  defp existing_rollup(nil),
    do: %ConversationRollup{
      source_count: 0,
      source_dependencies: [],
      source_refs: [],
      source_scopes: []
    }

  defp existing_rollup(%ConversationRollup{} = existing), do: existing

  defp existing_states(nil), do: []
  defp existing_states(existing), do: [{existing.period_end, existing.state}]

  defp latest_period_end(updated_at_values, nil), do: latest_datetime(updated_at_values)

  defp latest_period_end(updated_at_values, existing),
    do: latest_datetime([latest_datetime(updated_at_values), existing.period_end])

  defp bounded_source_refs(existing_refs, new_refs) do
    existing_refs
    |> Kernel.++(new_refs)
    |> Enum.uniq()
    |> Enum.sort()
    |> bounded_json_items(@maximum_rollup_source_refs, @maximum_rollup_source_ref_bytes)
  end

  defp merged_source_scopes(existing_scopes, sources) do
    existing_scopes
    |> Kernel.++(Enum.map(sources, &summary_source_scope/1))
    |> Enum.uniq()
    |> Enum.sort_by(&CanonicalJSON.encode!/1)
    |> exact_source_scopes()
  end

  defp rollup_repository_ref(:repository, scope_ref, _first), do: scope_ref
  defp rollup_repository_ref(_scope_kind, _scope_ref, first), do: first.repository_ref

  defp complete_compaction(_existing, sources, %{source_dependencies: nil}),
    do: defer_compaction(sources, "source_capacity")

  defp complete_compaction(_existing, sources, %{source_scopes: nil}),
    do: defer_compaction(sources, "scope_capacity")

  defp complete_compaction(existing, sources, attributes) do
    if DateTime.after?(attributes.expires_at, Repo.now!()) do
      persist_and_delete_compacted(existing, sources, attributes)
    else
      delete_expired_rollup(existing)
      {_count, nil} = delete_compacted_summaries(sources)
      :ok
    end
  end

  defp defer_compaction(sources, reason) do
    ids = Enum.map(sources, & &1.id)
    retry_at = DateTime.add(Repo.now!(), 3600, :second)

    Repo.update_all(from(s in ConversationSummary, where: s.id in ^ids),
      set: [compaction_error_code: reason, compaction_retry_at: retry_at]
    )

    :skipped
  end

  defp persist_and_delete_compacted(existing, sources, attributes) do
    with :ok <- persist_rollup(existing, attributes),
         {_count, nil} <- delete_compacted_summaries(sources) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp delete_expired_rollup(nil), do: :ok
  defp delete_expired_rollup(existing), do: Repo.delete!(existing)

  defp delete_compacted_summaries(sources) do
    Repo.delete_all(
      from(summary in ConversationSummary,
        where: summary.id in ^Enum.map(sources, & &1.id)
      )
    )
  end

  defp persist_rollup(nil, attributes) do
    id = Ecto.UUID.generate()
    now = Repo.now!()

    attributes
    |> Map.merge(%{id: id, ref: "continuity-rollup:#{id}"})
    |> rollup_changeset(%ConversationRollup{})
    |> Changeset.change(inserted_at: now, updated_at: now)
    |> Repo.insert()
    |> rollup_result()
  end

  defp persist_rollup(rollup, attributes) do
    attributes
    |> rollup_changeset(rollup)
    |> Changeset.force_change(:updated_at, Repo.now!())
    |> Repo.update()
    |> rollup_result()
  end

  defp rollup_changeset(attributes, rollup) do
    rollup
    |> Changeset.cast(attributes, [
      :expires_at,
      :id,
      :period_end,
      :period_start,
      :ref,
      :repository_ref,
      :scope_kind,
      :scope_ref,
      :source_count,
      :source_refs,
      :source_scopes,
      :source_dependencies,
      :state,
      :state_fingerprint,
      :visibility,
      :workspace_ref
    ])
    |> Changeset.validate_required([
      :expires_at,
      :period_end,
      :period_start,
      :scope_kind,
      :scope_ref,
      :source_count,
      :source_refs,
      :source_scopes,
      :state,
      :state_fingerprint,
      :visibility,
      :workspace_ref
    ])
    |> Changeset.unique_constraint(:ref)
    |> Changeset.unique_constraint([:workspace_ref, :scope_kind, :scope_ref, :period_start],
      name: :conversation_rollups_identity
    )
    |> Changeset.check_constraint(:scope_kind, name: :conversation_rollup_valid)
  end

  defp rollup_result({:ok, _rollup}), do: :ok

  defp rollup_result({:error, changeset}),
    do: {:error, {:conversation_rollup_persistence, changeset.errors}}

  defp merge_states(states) do
    states = Enum.sort_by(states, fn {updated_at, _state} -> updated_at end, {:desc, DateTime})
    list_fields = ConversationSummaryState.list_fields()

    base =
      Map.new(
        ConversationSummaryState.fields(),
        &{&1, initial_merged_value(&1, list_fields, states)}
      )

    Enum.reduce(list_fields, base, &merge_list_field(states, &1, &2))
  end

  defp initial_merged_value(field, list_fields, states) do
    if field in list_fields,
      do: [],
      else: Enum.find_value(states, fn {_updated_at, state} -> state[field] end)
  end

  defp merge_list_field(states, field, merged) do
    states
    |> Enum.flat_map(fn {_updated_at, state} -> state[field] end)
    |> Enum.uniq()
    |> Enum.take(20)
    |> Enum.reduce_while(merged, &append_bounded_value(&1, &2, field))
  end

  defp append_bounded_value(value, current, field) do
    candidate = Map.update!(current, field, &(&1 ++ [value]))

    if byte_size(CanonicalJSON.encode!(candidate)) <= @maximum_state_bytes,
      do: {:cont, candidate},
      else: {:halt, current}
  end

  defp summary_source_scope(summary) do
    case Scope.slack_channel(summary) do
      {workspace_ref, channel_ref} ->
        %{
          "channel_ref" => channel_ref,
          "transport" => "slack",
          "workspace_ref" => workspace_ref
        }

      nil ->
        %{"conversation_ref" => summary.conversation_ref, "transport" => summary.transport}
    end
  end

  defp exact_source_scopes(scopes) do
    if length(scopes) <= @maximum_rollup_source_scopes and
         byte_size(CanonicalJSON.encode!(scopes)) <= @maximum_rollup_source_scope_bytes,
       do: scopes
  end

  defp rollup_visibility(:repository, _summary), do: :public

  defp rollup_visibility(:conversation, summary) do
    case Scope.slack_channel(summary) do
      {workspace_ref, channel_ref} -> Scope.slack_visibility(workspace_ref, channel_ref)
      nil -> :conversation
    end
  end

  defp bounded_json_items(items, maximum_items, maximum_bytes) do
    items
    |> Enum.take(maximum_items)
    |> Enum.reduce_while([], fn item, kept ->
      candidate = kept ++ [item]

      if byte_size(CanonicalJSON.encode!(candidate)) <= maximum_bytes,
        do: {:cont, candidate},
        else: {:halt, kept}
    end)
  end

  defp beginning_of_week(datetime) do
    date = datetime |> DateTime.to_date() |> Date.beginning_of_week(:monday)
    DateTime.new!(date, ~T[00:00:00.000000], "Etc/UTC")
  end

  defp latest_datetime(values), do: Enum.max_by(values, &DateTime.to_unix(&1, :microsecond))
end
