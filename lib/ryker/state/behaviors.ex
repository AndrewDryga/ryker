defmodule Ryker.State.Behaviors do
  @moduledoc """
  Operator-confirmed durable behavior and guidance.

  Model tools may create inert offers only. This module rechecks the delivered
  control, derives scope from host-owned identity and destination, supersedes
  one exact logical entry, and exposes bounded retrieval. None of these records
  can widen Work, publication, or delivery authority.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Input
  alias Ryker.Operator.Actions
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.Slack.ChannelFence

  alias Ryker.State.{
    Behavior,
    BehaviorChangeset,
    CardDelivery,
    MemorySearchPage,
    MemorySourceLink,
    Record,
    RecordChangeset,
    Scope,
    SourceEventMatcher,
    StandingAssignmentRun,
    StandingAssignmentRunChangeset,
    StandingRuleInventory
  }

  alias Ryker.UTCDateTime
  alias Ryker.Work.Turn

  @confirmation_fields [:actor_ref, :confirmation_ref, :occurred_at, :record_ref, :target]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]
  @offer_kinds ~w(preference_offer guidance_offer standing_assignment_offer)
  @maximum_total 500
  @maximum_per_scope 100
  @runtime_candidate_limit 100
  @statuses [:active, :disabled, :superseded, :deleted, :expired]

  @spec confirm(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def confirm(attributes) do
    with {:ok, attributes} <- confirmation_attributes(attributes),
         :ok <- reference(attributes.actor_ref, :actor_ref),
         :ok <- reference(attributes.confirmation_ref, :confirmation_ref),
         :ok <- reference(attributes.record_ref, :record_ref),
         {:ok, occurred_at} <- utc_datetime(attributes.occurred_at, :occurred_at),
         {:ok, target} <- target(attributes.target) do
      Repo.transaction(fn ->
        confirm_locked(%{attributes | occurred_at: occurred_at, target: target})
      end)
    end
  end

  @spec set_status(String.t(), :active | :disabled | :deleted) ::
          {:ok, Behavior.t()} | {:error, term()}
  def set_status(ref, status) when status in [:active, :disabled, :deleted] do
    with :ok <- reference(ref, :behavior_ref) do
      Repo.transaction(fn -> set_status_locked(ref, status, nil) end)
    end
  end

  def set_status(_ref, _status), do: {:error, {:invalid_behavior, :status}}

  @spec set_status(String.t(), :active | :disabled | :deleted, String.t()) ::
          {:ok, Behavior.t()} | {:error, term()}
  def set_status(ref, status, workspace_ref) when status in [:active, :disabled, :deleted] do
    with :ok <- reference(ref, :behavior_ref),
         :ok <- reference(workspace_ref, :workspace_ref) do
      Repo.transaction(fn -> set_status_locked(ref, status, workspace_ref) end)
    end
  end

  def set_status(_ref, _status, _workspace_ref), do: {:error, {:invalid_behavior, :status}}

  @doc "Changes shared or actor-owned App Home behavior without crossing channel scope."
  @spec set_home_status(String.t(), :active | :disabled | :deleted, String.t(), String.t()) ::
          {:ok, Behavior.t()} | {:error, term()}
  def set_home_status(ref, status, actor_ref, workspace_ref)
      when status in [:active, :disabled, :deleted] do
    with :ok <- reference(ref, :behavior_ref),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(workspace_ref, :workspace_ref) do
      Repo.transaction(fn -> set_home_status_locked(ref, status, actor_ref, workspace_ref) end)
    end
  end

  def set_home_status(_ref, _status, _actor_ref, _workspace_ref),
    do: {:error, {:invalid_behavior, :status}}

  @doc "Changes one App Home behavior through revision-fenced operator action custody."
  @spec set_home_status(
          String.t(),
          :active | :disabled | :deleted,
          pos_integer(),
          String.t(),
          String.t(),
          String.t()
        ) :: {:ok, map()} | {:error, term()}
  def set_home_status(ref, status, expected_revision, actor_ref, workspace_ref, action_ref)
      when status in [:active, :disabled, :deleted] and is_integer(expected_revision) and
             expected_revision > 0 do
    with :ok <- reference(ref, :behavior_ref),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- reference(action_ref, :action_ref) do
      Actions.run(
        %{
          action: :update,
          action_ref: action_ref,
          actor_ref: actor_ref,
          kind: "behavior",
          request: %{
            "expected_revision" => expected_revision,
            "status" => Atom.to_string(status),
            "workspace_ref" => workspace_ref
          },
          resource_ref: ref
        },
        fn ->
          set_home_status_audited_locked(
            ref,
            status,
            expected_revision,
            actor_ref,
            workspace_ref
          )
        end
      )
    end
  end

  def set_home_status(
        _ref,
        _status,
        _expected_revision,
        _actor_ref,
        _workspace_ref,
        _action_ref
      ),
      do: {:error, {:invalid_behavior, :status}}

  defp set_home_status_locked(ref, status, actor_ref, workspace_ref) do
    case Repo.one(from(behavior in Behavior, where: behavior.ref == ^ref, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:behavior_not_found)

      %Behavior{workspace_ref: actual} when actual != workspace_ref ->
        Repo.rollback(:behavior_workspace_mismatch)

      %Behavior{} = behavior ->
        set_visible_home_status(behavior, ref, status, actor_ref, workspace_ref)
    end
  end

  defp set_home_status_audited_locked(
         ref,
         status,
         expected_revision,
         actor_ref,
         workspace_ref
       ) do
    case Repo.one(from(behavior in Behavior, where: behavior.ref == ^ref, lock: "FOR UPDATE")) do
      nil ->
        {:error, :behavior_not_found}

      %Behavior{workspace_ref: actual} when actual != workspace_ref ->
        {:error, :behavior_workspace_mismatch}

      %Behavior{revision: actual} when actual != expected_revision ->
        {:error, :behavior_revision_stale}

      %Behavior{} = behavior ->
        if home_behavior_visible?(behavior, actor_ref) do
          updated = set_status_locked(ref, status, workspace_ref)

          {:ok,
           %{
             previous: %{
               "revision" => behavior.revision,
               "status" => Atom.to_string(behavior.status)
             },
             outcome: %{
               "revision" => updated.revision,
               "status" => Atom.to_string(updated.status)
             }
           }}
        else
          {:error, :behavior_unauthorized}
        end
    end
  end

  defp set_visible_home_status(behavior, ref, status, actor_ref, workspace_ref) do
    if home_behavior_visible?(behavior, actor_ref),
      do: set_status_locked(ref, status, workspace_ref),
      else: Repo.rollback(:behavior_unauthorized)
  end

  @spec assignments_for_channel(String.t(), String.t()) :: [Behavior.t()]
  def assignments_for_channel(workspace_ref, conversation_ref) do
    if Reference.valid?(workspace_ref) and Reference.valid?(conversation_ref) do
      now = Repo.now!()

      Repo.all(
        from(behavior in Behavior,
          where:
            behavior.kind == :standing_assignment and
              behavior.workspace_ref == ^workspace_ref and
              behavior.scope_kind == :conversation and behavior.scope_ref == ^conversation_ref and
              behavior.status in [:active, :disabled] and
              (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
          order_by: [asc: behavior.inserted_at, asc: behavior.id],
          limit: 100
        )
      )
    else
      []
    end
  end

  @spec manage_assignment(String.t(), :active | :disabled | :deleted, String.t(), String.t()) ::
          {:ok, Behavior.t()} | {:error, term()}
  def manage_assignment(ref, status, workspace_ref, conversation_ref)
      when status in [:active, :disabled, :deleted] do
    with :ok <- reference(ref, :behavior_ref),
         :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- reference(conversation_ref, :conversation_ref) do
      Repo.transaction(fn ->
        manage_assignment_locked(ref, status, workspace_ref, conversation_ref)
      end)
    end
  end

  def manage_assignment(_ref, _status, _workspace_ref, _conversation_ref),
    do: {:error, {:invalid_behavior, :assignment}}

  defp manage_assignment_locked(ref, status, workspace_ref, conversation_ref) do
    query = from(behavior in Behavior, where: behavior.ref == ^ref, lock: "FOR UPDATE")

    case Repo.one(query) do
      %Behavior{
        kind: :standing_assignment,
        scope_kind: :conversation,
        workspace_ref: ^workspace_ref,
        scope_ref: ^conversation_ref
      } ->
        update_assignment_status(ref, status, workspace_ref)

      %Behavior{} ->
        Repo.rollback(:assignment_scope_mismatch)

      nil ->
        Repo.rollback(:behavior_not_found)
    end
  end

  defp update_assignment_status(ref, status, workspace_ref) do
    case set_status_locked(ref, status, workspace_ref) do
      {:error, reason} -> Repo.rollback(reason)
      behavior -> behavior
    end
  end

  @spec effective_preferences(map()) :: %{String.t() => map()}
  def effective_preferences(context) when is_map(context) do
    case retrieval_context(context) do
      {:ok, context} -> preference_context(context)
      {:error, _reason} -> %{}
    end
  end

  def effective_preferences(_context), do: %{}

  defp preference_context(context) do
    active_for_context(:preference, context)
    |> Enum.sort_by(&preference_rank/1)
    |> Enum.reduce(%{}, fn behavior, preferences ->
      Map.put_new(preferences, behavior.payload["key"], %{
        "behavior_ref" => behavior.ref,
        "scope" => Atom.to_string(behavior.scope_kind),
        "value" => behavior.payload["value"]
      })
    end)
  end

  @doc "Returns the bounded confirmed behavior context for one exact episode turn."
  @spec model_context(Episode.t(), String.t(), String.t() | nil) :: map()
  def model_context(%Episode{} = episode, operator_ref, repository)
      when is_binary(operator_ref) and (is_binary(repository) or is_nil(repository)) do
    context = %{
      conversation_ref: episode.destination_conversation_ref,
      operator_ref: operator_ref,
      repository: repository,
      workspace_ref: Scope.workspace_ref(episode)
    }

    %{
      "guidance" => guidance(context),
      "preferences" => effective_preferences(context),
      "standing_assignments" => assignment_context(episode.id)
    }
  end

  def model_context(_episode, _operator_ref, _repository),
    do: %{"guidance" => [], "preferences" => %{}, "standing_assignments" => []}

  @spec guidance(map(), pos_integer()) :: [map()]
  def guidance(context, limit \\ 20)

  def guidance(context, limit) when is_map(context) and is_integer(limit) and limit in 1..50 do
    case retrieval_context(context) do
      {:ok, context} -> guidance_context(context, limit)
      {:error, _reason} -> []
    end
  end

  def guidance(_context, _limit), do: []

  @spec search_guidance(map(), String.t(), String.t(), pos_integer()) :: [map()]
  def search_guidance(context, query, scope, limit)
      when is_map(context) and is_binary(query) and is_binary(scope) and is_integer(limit) and
             limit in 1..50 do
    with {:ok, context} <- retrieval_context(context),
         {:ok, documents} <-
           Repo.transaction(fn ->
             MemorySearchPage.read(
               MemorySearchPage.first(query, scope),
               limit,
               &search_page(context, &1)
             )
           end) do
      documents
    else
      _ -> []
    end
  end

  def search_guidance(_context, _query, _scope, _limit), do: []

  defp guidance_context(context, limit) do
    active_for_context(:guidance, context)
    |> Enum.sort_by(&{preference_rank(&1), DateTime.to_unix(&1.updated_at, :microsecond) * -1})
    |> Enum.take(limit)
    |> account_guidance()
  end

  defp account_guidance([]), do: []

  defp account_guidance(behaviors) do
    now = Repo.now!()

    unchanged =
      Enum.reduce(behaviors, dynamic(false), fn behavior, condition ->
        dynamic(
          [current],
          ^condition or
            (current.id == ^behavior.id and current.payload == ^behavior.payload and
               current.revision == ^behavior.revision)
        )
      end)

    {_count, ids} =
      Repo.update_all(
        from(behavior in Behavior,
          where: ^unchanged,
          where:
            behavior.status == :active and
              (is_nil(behavior.expires_at) or behavior.expires_at > fragment("clock_timestamp()")),
          select: behavior.id
        ),
        inc: [use_count: 1],
        set: [last_used_at: now]
      )

    retained = MapSet.new(ids)
    behaviors |> Enum.filter(&MapSet.member?(retained, &1.id)) |> Enum.map(&guidance_document/1)
  end

  defp guidance_document(behavior) do
    %{
      "behavior_ref" => behavior.ref,
      "confirmed_at" => DateTime.to_iso8601(behavior.confirmed_at),
      "expires_at" => if(behavior.expires_at, do: DateTime.to_iso8601(behavior.expires_at)),
      "source_read" =>
        MemorySourceLink.message(
          behavior.source_transport,
          behavior.source_conversation_ref,
          behavior.source_message_ref,
          behavior.source_thread_ref
        ),
      "kind" => "guidance",
      "scope" => Atom.to_string(behavior.scope_kind),
      "subject" => behavior.payload["subject"],
      "summary" => behavior.payload["summary"],
      "text" => behavior.payload["text"],
      "visibility" => behavior.payload["visibility"]
    }
    |> put_edit_provenance(behavior)
  end

  defp put_edit_provenance(document, %Behavior{edited_at: %DateTime{} = edited_at} = behavior) do
    Map.put(document, "edit", %{
      "actor_ref" => behavior.edited_by_actor_ref,
      "edited_at" => DateTime.to_iso8601(edited_at),
      "review_ref" => behavior.edit_review_ref
    })
  end

  defp put_edit_provenance(document, _behavior), do: document

  @doc false
  def search_page(context, page) do
    case retrieval_context(context) do
      {:ok, context} -> search_visible_page(context, page)
      _ -> :done
    end
  end

  defp search_visible_page(context, page) do
    scoped = search_scope(context, page.scope)
    visible = behavior_visibility_filter(:guidance, context)

    query =
      from(b in Behavior,
        where:
          b.workspace_ref == ^context.workspace_ref and b.kind == :guidance and
            b.status == :active and
            (is_nil(b.expires_at) or b.expires_at > fragment("clock_timestamp()")),
        where: ^scoped,
        where: ^visible
      )

    changed =
      dynamic(
        [b],
        type(fragment("COALESCE(?, ?)", b.edited_at, b.confirmed_at), :utc_datetime_usec)
      )

    query
    |> MemorySearchPage.related_originals(
      page,
      dynamic([b], b.source_conversation_ref),
      dynamic([b], b.source_thread_ref),
      dynamic([b], b.source_message_ref)
    )
    |> MemorySearchPage.one(
      page,
      dynamic([b], b.payload),
      changed,
      dynamic([b], b.confirmed_at)
    )
    |> account_search_result()
  end

  defp search_scope(context, "current_channel"),
    do: dynamic([b], b.scope_kind == :conversation and b.scope_ref == ^context.conversation_ref)

  defp search_scope(%{repository: repository}, "repository") when is_binary(repository),
    do: dynamic([b], b.scope_kind == :repository and b.scope_ref == ^repository)

  defp search_scope(context, "workspace"),
    do: dynamic([b], b.scope_kind == :workspace and b.scope_ref == ^context.workspace_ref)

  defp search_scope(%{operator_ref: operator}, "mine") when is_binary(operator),
    do: dynamic([b], b.scope_kind == :operator and b.scope_ref == ^operator)

  defp search_scope(_context, _scope), do: dynamic([b], false)

  defp account_search_result({:ok, behavior, position}) do
    case account_guidance([behavior]) do
      [document] -> {:ok, document, position}
      [] -> {:skip, position}
    end
  end

  defp account_search_result(:done), do: :done

  @doc "Returns true only when an active channel assignment matches trusted source identity and event shape."
  @spec standing_match?(Input.t()) :: boolean()
  def standing_match?(%Input{} = input), do: matching_assignments(input, false) != []

  def standing_match?(_input), do: false

  @inventory_limit 200

  @doc """
  Records every standing rule that existed in this input's workspace, with the
  verdict each one got.

  This is observation, not scheduling. It reads a wider set than
  `matching_assignments/2` deliberately -- including rules in other
  conversations, paused rules and expired rules -- and none of what it reads
  can start work. Routing the enumerated matches into scheduling would turn an
  inspection change into a behaviour change, which is how observability breaks
  production.

  It is also optional. A failure here loses a diagnosis; failing the input
  would lose the answer the operator asked for, so errors are swallowed and the
  absent row honestly reads as "not recorded".
  """
  @spec record_rule_inventory(Input.t(), String.t()) ::
          {:ok, StandingRuleInventory.t()} | {:error, term()}
  def record_rule_inventory(%Input{} = input, input_ref) when is_binary(input_ref) do
    with :ok <- reference(input_ref, :input_ref) do
      # Its own short transaction: in production a failure here rolls back
      # nothing else, and under a test sandbox it is a savepoint, so a poisoned
      # statement cannot abort the caller's transaction either way.
      Repo.transaction(fn -> record_rule_inventory_locked(input, input_ref) end)
    end
  rescue
    error -> {:error, {:standing_rule_inventory_failed, error.__struct__}}
  end

  def record_rule_inventory(_input, _input_ref),
    do: {:error, {:invalid_standing_rule_inventory, :input}}

  defp record_rule_inventory_locked(input, input_ref) do
    now = Repo.now!()

    workspace =
      Scope.workspace_ref(input.destination.transport, input.destination.conversation_ref)

    rules = workspace_rules(workspace)
    listed = Enum.take(rules, @inventory_limit)

    considered =
      input
      |> runtime_candidates(now)
      |> select([behavior], behavior.id)
      |> Repo.all()
      |> MapSet.new()

    entries = Enum.map(listed, &inventory_entry(&1, input, now, considered))

    case Repo.insert(
           %StandingRuleInventory{
             id: Ecto.UUID.generate(),
             source_input_ref: input_ref,
             source_event_ref: input.event_ref,
             workspace_ref: workspace,
             conversation_ref: input.destination.conversation_ref,
             rule_count: length(rules),
             matched_count: Enum.count(entries, &(&1["verdict"] == "matched")),
             truncated: length(rules) > length(listed),
             entries: entries,
             recorded_at: now
           },
           on_conflict: :nothing,
           conflict_target: :source_input_ref
         ) do
      {:ok, inventory} -> inventory
      {:error, changeset} -> Repo.rollback({:standing_rule_inventory_failed, changeset.errors})
    end
  end

  @doc "The recorded rule inventory for one input, or nil when none was recorded."
  @spec rule_inventory(String.t()) :: StandingRuleInventory.t() | nil
  def rule_inventory(input_ref) when is_binary(input_ref),
    do: Repo.one(from(row in StandingRuleInventory, where: row.source_input_ref == ^input_ref))

  def rule_inventory(_input_ref), do: nil

  @doc "Recorded inventories for many inputs in one query, keyed by input reference."
  @spec rule_inventories([String.t()]) :: %{String.t() => StandingRuleInventory.t()}
  def rule_inventories([]), do: %{}

  def rule_inventories(input_refs) when is_list(input_refs) do
    refs = Enum.filter(input_refs, &is_binary/1)

    from(row in StandingRuleInventory, where: row.source_input_ref in ^refs)
    |> Repo.all()
    |> Map.new(&{&1.source_input_ref, &1})
  end

  # Deliberately wider than the scheduling query: a reader needs to see the rule
  # that did not fire and why, and a rule scoped to another channel is a reason,
  # not an absence.
  defp workspace_rules(workspace) do
    Repo.all(
      from(behavior in Behavior,
        where:
          behavior.kind == :standing_assignment and behavior.workspace_ref == ^workspace and
            behavior.status not in [:deleted, :superseded],
        order_by: [asc: behavior.inserted_at, asc: behavior.id],
        limit: @inventory_limit + 1
      )
    )
  end

  defp inventory_entry(behavior, input, now, considered) do
    {verdict, reason} = inventory_verdict(behavior, input, now, considered)

    %{
      "ref" => behavior.ref,
      "title" => assignment_title(behavior.payload),
      "status" => Atom.to_string(behavior.status),
      "scope_ref" => behavior.scope_ref,
      "revision" => behavior.revision,
      "verdict" => verdict,
      "reason" => reason
    }
  end

  defp inventory_verdict(%Behavior{status: status}, _input, _now, _considered)
       when status != :active,
       do: {Atom.to_string(status), "This rule was #{status} when the input was processed."}

  defp inventory_verdict(
         %Behavior{expires_at: %DateTime{} = expires_at} = behavior,
         input,
         now,
         considered
       ) do
    if DateTime.compare(expires_at, now) == :gt,
      do: inventory_verdict(%{behavior | expires_at: nil}, input, now, considered),
      else: {"expired", "This rule had expired when the input was processed."}
  end

  defp inventory_verdict(%Behavior{scope_kind: scope_kind}, _input, _now, _considered)
       when scope_kind != :conversation,
       do: {"out_of_scope", "This rule is not scoped to a conversation."}

  defp inventory_verdict(%Behavior{scope_ref: scope_ref} = behavior, input, _now, considered) do
    cond do
      scope_ref != input.destination.conversation_ref ->
        {"out_of_scope",
         "Applies to #{scope_ref}; this input arrived in #{input.destination.conversation_ref}."}

      # Outside the runtime's candidate window the predicate was never run.
      # Calling such a rule "matched" would credit it with an engagement it
      # could not have caused.
      not MapSet.member?(considered, behavior.id) ->
        {"not_considered",
         "Outside the #{@runtime_candidate_limit}-rule window the runtime evaluates for one conversation; its trigger was not checked."}

      assignment_matches?(behavior.payload, input) ->
        {"matched", assignment_match_reason(behavior.payload, input)}

      true ->
        {"not_matched", assignment_mismatch_reason(behavior.payload, input)}
    end
  end

  defp assignment_title(%{"title" => title}) when is_binary(title), do: title
  defp assignment_title(%{"task" => task}) when is_binary(task), do: task
  defp assignment_title(_payload), do: nil

  defp assignment_match_reason(%{"trigger" => trigger}, input) when is_binary(trigger),
    do: "A #{human(trigger)} from #{human(to_string(input.actor.kind))} in this conversation."

  defp assignment_match_reason(_payload, _input),
    do: "The recorded source and event filter matched this input."

  defp assignment_mismatch_reason(payload, input) do
    cond do
      not source_matches?(payload["source_filter"], input.actor.kind) ->
        "Applies to #{human(to_string(payload["source_filter"]))} senders; this input came from #{human(to_string(input.actor.kind))}."

      is_binary(payload["trigger"]) ->
        "This event does not match the #{human(payload["trigger"])} trigger."

      true ->
        "The recorded source and event filter did not match this input."
    end
  end

  defp human(value) when is_binary(value), do: String.replace(value, "_", " ")
  defp human(value), do: to_string(value)

  @doc false
  @spec observe_input(Input.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def observe_input(%Input{} = input, input_ref) do
    with :ok <- reference(input_ref, :input_ref) do
      transaction(fn -> observe_input_locked(input, input_ref) end)
    end
  end

  def observe_input(_input, _input_ref), do: {:error, {:invalid_behavior_run, :input}}

  @doc false
  @spec finalize_assignment_runs_in_transaction(
          String.t(),
          :start_episode | :continue_episode | :reply | :react | :ignore,
          String.t(),
          Episode.t() | nil,
          :decided | :superseded
        ) :: :ok | {:error, term()}
  def finalize_assignment_runs_in_transaction(
        input_ref,
        action,
        decision_ref,
        episode,
        outcome
      )
      when action in [:start_episode, :continue_episode, :reply, :react, :ignore] and
             outcome in [:decided, :superseded] do
    with true <- Repo.in_transaction?(),
         :ok <- reference(input_ref, :input_ref),
         :ok <- reference(decision_ref, :decision_ref),
         :ok <- valid_final_episode(action, episode) do
      finalize_assignment_runs_locked(input_ref, action, decision_ref, episode, outcome)
    else
      false -> {:error, :behavior_run_transaction_required}
      {:error, _reason} = error -> error
    end
  end

  def finalize_assignment_runs_in_transaction(
        _input_ref,
        _action,
        _decision_ref,
        _episode,
        _outcome
      ),
      do: {:error, {:invalid_behavior_run, :decision}}

  @spec list(String.t(), keyword()) :: [Behavior.t()]
  def list(workspace_ref, options \\ []) do
    status = Keyword.get(options, :status)
    limit = Keyword.get(options, :limit, 100)

    if Reference.valid?(workspace_ref) and (is_nil(status) or status in @statuses) and
         is_integer(limit) and limit in 1..100 do
      query = from(behavior in Behavior, where: behavior.workspace_ref == ^workspace_ref)

      query =
        if status, do: from(behavior in query, where: behavior.status == ^status), else: query

      Repo.all(
        from(behavior in query,
          order_by: [desc: behavior.updated_at, desc: behavior.id],
          limit: ^limit
        )
      )
    else
      []
    end
  end

  defp confirm_locked(attributes) do
    with {:ok, record, episode, turn} <- lock_offer(attributes.record_ref),
         :ok <-
           ChannelFence.authorize_in_transaction(
             episode.destination_transport,
             episode.destination_conversation_ref
           ),
         :ok <- authorize_wide_guidance(record, episode),
         :ok <- delivered_from?(episode, turn, attributes.target) do
      case Repo.one(from(behavior in Behavior, where: behavior.offer_record_id == ^record.id)) do
        %Behavior{} = behavior ->
          %{behavior: behavior, status: :duplicate}

        nil when record.status == :open ->
          create_behavior(record, episode, attributes)

        nil ->
          Repo.rollback(:behavior_offer_stale)
      end
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_wide_guidance(
         %Record{kind: "guidance_offer", payload: %{"scope" => scope}},
         %Episode{destination_transport: "slack"} = episode
       )
       when scope in ["repository", "workspace"] do
    ChannelFence.authorize_public_in_transaction(
      episode.destination_transport,
      episode.destination_conversation_ref
    )
  end

  defp authorize_wide_guidance(_record, _episode), do: :ok

  defp create_behavior(record, episode, attributes) do
    with {:ok, prepared} <- prepare_behavior(record, episode, attributes),
         :ok <- capacity(prepared),
         :ok <- supersede_existing(prepared),
         {:ok, behavior} <- insert_behavior(record, episode, attributes, prepared),
         {:ok, _record} <-
           record
           |> RecordChangeset.confirm_resource(%{
             confirmed_at: attributes.occurred_at,
             confirmed_by_actor_ref: attributes.actor_ref,
             confirmation_ref: attributes.confirmation_ref,
             status: :confirmed
           })
           |> Repo.update() do
      %{behavior: behavior, status: :confirmed}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prepare_behavior(%Record{kind: "preference_offer", payload: payload}, episode, attributes) do
    prepare_scoped(:preference, payload["key"], payload, episode, attributes)
  end

  defp prepare_behavior(%Record{kind: "guidance_offer", payload: payload}, episode, attributes) do
    prepare_scoped(:guidance, payload["subject"], payload, episode, attributes)
  end

  defp prepare_behavior(
         %Record{kind: "standing_assignment_offer", payload: %{"source_kind" => _} = payload},
         episode,
         attributes
       ) do
    workspace = Scope.workspace_ref(episode)

    with {:ok, expires_at} <- source_event_expiry(payload["expires_at"], attributes.occurred_at) do
      {:ok,
       %{
         expires_at: expires_at,
         identity_key: source_event_identity(payload),
         kind: :standing_assignment,
         payload: payload,
         scope_kind: :conversation,
         scope_ref: episode.destination_conversation_ref,
         workspace_ref: workspace
       }}
    end
  end

  defp prepare_behavior(
         %Record{kind: "standing_assignment_offer", payload: payload},
         episode,
         attributes
       ) do
    workspace = Scope.workspace_ref(episode)

    {:ok,
     %{
       expires_at: expires_at(attributes.occurred_at, payload["expires_in"]),
       identity_key: payload["trigger"],
       kind: :standing_assignment,
       payload: payload,
       scope_kind: :conversation,
       scope_ref: episode.destination_conversation_ref,
       workspace_ref: workspace
     }}
  end

  defp prepare_scoped(kind, identity_key, payload, episode, attributes) do
    workspace = Scope.workspace_ref(episode)
    scope_kind = scope_kind(payload["scope"])

    scope_ref =
      case scope_kind do
        :workspace -> workspace
        :conversation -> episode.destination_conversation_ref
        :repository -> payload["repository"]
        :operator -> attributes.actor_ref
      end

    {:ok,
     %{
       expires_at: expires_at(attributes.occurred_at, payload["expires_in"]),
       identity_key: identity_key,
       kind: kind,
       payload: payload,
       scope_kind: scope_kind,
       scope_ref: scope_ref,
       workspace_ref: workspace
     }}
  end

  defp capacity(prepared) do
    now = Repo.now!()

    existing? = existing_behavior?(prepared)
    total = active_behavior_count(prepared.workspace_ref, now)
    scoped = scoped_behavior_count(prepared, now)

    if existing? or (total < @maximum_total and scoped < @maximum_per_scope),
      do: :ok,
      else: {:error, :behavior_capacity_reached}
  end

  defp existing_behavior?(prepared) do
    Repo.exists?(
      from(behavior in Behavior,
        where:
          behavior.kind == ^prepared.kind and behavior.workspace_ref == ^prepared.workspace_ref and
            behavior.scope_kind == ^prepared.scope_kind and
            behavior.scope_ref == ^prepared.scope_ref and
            behavior.identity_key == ^prepared.identity_key and behavior.status == :active
      )
    )
  end

  defp active_behavior_count(workspace_ref, now) do
    Repo.aggregate(
      from(behavior in Behavior,
        where:
          behavior.workspace_ref == ^workspace_ref and behavior.status == :active and
            (is_nil(behavior.expires_at) or behavior.expires_at > ^now)
      ),
      :count
    )
  end

  defp scoped_behavior_count(prepared, now) do
    Repo.aggregate(
      from(behavior in Behavior,
        where:
          behavior.workspace_ref == ^prepared.workspace_ref and
            behavior.scope_kind == ^prepared.scope_kind and
            behavior.scope_ref == ^prepared.scope_ref and behavior.status == :active and
            (is_nil(behavior.expires_at) or behavior.expires_at > ^now)
      ),
      :count
    )
  end

  defp supersede_existing(prepared) do
    _updated =
      Repo.update_all(
        from(behavior in Behavior,
          where:
            behavior.kind == ^prepared.kind and behavior.workspace_ref == ^prepared.workspace_ref and
              behavior.scope_kind == ^prepared.scope_kind and
              behavior.scope_ref == ^prepared.scope_ref and
              behavior.identity_key == ^prepared.identity_key and behavior.status == :active
        ),
        set: [status: :superseded, updated_at: Repo.now!()],
        inc: [revision: 1]
      )

    :ok
  end

  defp insert_behavior(record, episode, attributes, prepared) do
    id = Ecto.UUID.generate()
    now = Repo.now!()

    prepared
    |> Map.merge(%{
      confirmation_ref: attributes.confirmation_ref,
      confirmed_at: attributes.occurred_at,
      confirmed_by_actor_ref: attributes.actor_ref,
      id: id,
      offer_record_id: record.id,
      ref: "behavior:#{id}",
      source_conversation_ref: episode.destination_conversation_ref,
      source_message_ref: attributes.target.message_ref,
      source_thread_ref: attributes.target.thread_ref,
      source_transport: episode.destination_transport,
      status: :active
    })
    |> BehaviorChangeset.insert()
    |> Ecto.Changeset.put_change(:inserted_at, now)
    |> Ecto.Changeset.put_change(:updated_at, now)
    |> Repo.insert()
    |> case do
      {:ok, behavior} -> {:ok, behavior}
      {:error, changeset} -> {:error, {:behavior_persistence_failed, changeset.errors}}
    end
  end

  defp set_status_locked(ref, status, workspace_ref) do
    case Repo.one(from(behavior in Behavior, where: behavior.ref == ^ref, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback(:behavior_not_found)

      %Behavior{workspace_ref: actual}
      when not is_nil(workspace_ref) and actual != workspace_ref ->
        Repo.rollback(:behavior_workspace_mismatch)

      %Behavior{status: ^status} = behavior ->
        behavior

      %Behavior{status: current} when current in [:deleted, :expired, :superseded] ->
        Repo.rollback(:behavior_terminal)

      %Behavior{} = behavior ->
        if status == :active, do: supersede_existing(Map.from_struct(behavior))

        behavior
        |> BehaviorChangeset.update(%{revision: behavior.revision + 1, status: status})
        |> Repo.update!()
    end
  end

  defp active_for_context(kind, context) do
    now = Repo.now!()

    scope_filter =
      Enum.reduce(context_clauses(context), dynamic([behavior], false), fn {scope_kind, scope_ref},
                                                                           dynamic ->
        dynamic(
          [behavior],
          ^dynamic or (behavior.scope_kind == ^scope_kind and behavior.scope_ref == ^scope_ref)
        )
      end)

    visibility_filter = behavior_visibility_filter(kind, context)

    query =
      from(behavior in Behavior,
        where:
          behavior.kind == ^kind and behavior.status == :active and
            behavior.workspace_ref == ^context.workspace_ref and
            (is_nil(behavior.expires_at) or behavior.expires_at > ^now)
      )

    Repo.all(
      from(behavior in query,
        where: ^scope_filter,
        where: ^visibility_filter,
        order_by: [
          asc:
            fragment(
              "CASE ? WHEN 'operator' THEN 0 WHEN 'conversation' THEN 1 WHEN 'repository' THEN 2 WHEN 'workspace' THEN 3 ELSE 4 END",
              behavior.scope_kind
            ),
          desc: behavior.updated_at,
          desc: behavior.id
        ],
        limit: 100
      )
    )
  end

  defp behavior_visibility_filter(:guidance, context) do
    dynamic(
      [behavior],
      fragment("(?::jsonb)->>'visibility'", behavior.payload) == "workspace" or
        (behavior.scope_kind == :operator and
           fragment("(?::jsonb)->>'visibility'", behavior.payload) == "private" and
           behavior.scope_ref == ^context.operator_ref) or
        (fragment(
           "(?::jsonb)->>'visibility' IN ('conversation', 'private')",
           behavior.payload
         ) and
           behavior.source_conversation_ref == ^context.conversation_ref)
    )
  end

  defp behavior_visibility_filter(_kind, _context), do: dynamic([_behavior], true)

  defp assignment_context(episode_id) do
    Repo.all(
      from(run in StandingAssignmentRun,
        join: behavior in Behavior,
        on: behavior.id == run.assignment_id,
        where:
          run.episode_id == ^episode_id and run.outcome == :decided and
            behavior.kind == :standing_assignment,
        order_by: [desc: run.inserted_at],
        limit: 5,
        select: {run, behavior}
      )
    )
    |> Enum.reverse()
    |> Enum.map(fn {_run, behavior} ->
      %{
        "action" => behavior.payload["action"] || "run_source_event_automation",
        "allowed_outputs" => ["ignore", "react", "reply"],
        "assignment_ref" => behavior.ref,
        "authority_ceiling" => "read_only",
        "repository" => behavior.payload["repository"],
        "task" => behavior.payload["task"],
        "trigger" =>
          behavior.payload["trigger"] ||
            %{
              "filter" => behavior.payload["filter"],
              "source_kind" => behavior.payload["source_kind"]
            }
      }
    end)
  end

  defp matching_assignments(input, lock?) do
    query = runtime_candidates(input, Repo.now!())
    query = if lock?, do: from(behavior in query, lock: "FOR SHARE"), else: query

    query
    |> Repo.all()
    |> Enum.filter(&assignment_matches?(&1.payload, input))
  end

  # The exact rules the runtime considers for one input. Shared with the
  # inventory recorder so "not considered" there means precisely "outside this
  # window", never a second opinion about eligibility.
  defp runtime_candidates(input, now) do
    workspace =
      Scope.workspace_ref(input.destination.transport, input.destination.conversation_ref)

    from(behavior in Behavior,
      where:
        behavior.kind == :standing_assignment and behavior.status == :active and
          behavior.workspace_ref == ^workspace and behavior.scope_kind == :conversation and
          behavior.scope_ref == ^input.destination.conversation_ref and
          (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
      order_by: [asc: behavior.inserted_at],
      limit: @runtime_candidate_limit
    )
  end

  defp observe_input_locked(input, input_ref) do
    assignments = matching_assignments(input, true)
    Enum.each(assignments, &insert_assignment_run!(&1, input, input_ref))

    length(assignments)
  end

  defp insert_assignment_run!(assignment, input, input_ref) do
    case Repo.one(
           from(run in StandingAssignmentRun,
             where: run.assignment_id == ^assignment.id and run.source_input_ref == ^input_ref,
             lock: "FOR UPDATE"
           )
         ) do
      %StandingAssignmentRun{source_event_ref: event_ref}
      when event_ref == input.event_ref ->
        :ok

      %StandingAssignmentRun{} ->
        Repo.rollback(:standing_assignment_run_conflict)

      nil ->
        digest = CanonicalJSON.digest([assignment.id, input_ref])

        case Repo.insert(
               StandingAssignmentRunChangeset.insert(%{
                 assignment_id: assignment.id,
                 id: Ecto.UUID.generate(),
                 outcome: :pending,
                 ref: "assignment-run:#{digest}",
                 source_event_ref: input.event_ref,
                 source_input_ref: input_ref
               })
             ) do
          {:ok, _run} ->
            :ok

          {:error, changeset} ->
            Repo.rollback({:standing_assignment_run_failed, changeset.errors})
        end
    end
  end

  defp finalize_assignment_runs_locked(input_ref, action, decision_ref, episode, outcome) do
    now = Repo.now!()
    episode_id = if action in [:start_episode, :continue_episode, :reply], do: episode.id

    Repo.all(
      from(run in StandingAssignmentRun,
        where: run.source_input_ref == ^input_ref,
        order_by: [asc: run.inserted_at],
        lock: "FOR UPDATE"
      )
    )
    |> Enum.each(fn run ->
      desired = %{
        decision_action: action,
        decision_ref: decision_ref,
        episode_id: episode_id,
        outcome: outcome
      }

      finalize_assignment_run(run, desired, now)
    end)

    :ok
  end

  defp finalize_assignment_run(%StandingAssignmentRun{outcome: :pending} = run, desired, now) do
    case run |> StandingAssignmentRunChangeset.finalize(desired) |> Repo.update() do
      {:ok, _updated} -> increment_assignment_use(run.assignment_id, now)
      {:error, changeset} -> Repo.rollback({:standing_assignment_run_failed, changeset.errors})
    end
  end

  defp finalize_assignment_run(%StandingAssignmentRun{} = existing, desired, _now) do
    if Map.take(existing, [:decision_action, :decision_ref, :episode_id, :outcome]) == desired,
      do: :ok,
      else: Repo.rollback(:standing_assignment_run_conflict)
  end

  defp increment_assignment_use(assignment_id, now) do
    _count =
      Repo.update_all(
        from(behavior in Behavior, where: behavior.id == ^assignment_id),
        inc: [use_count: 1],
        set: [last_used_at: now, updated_at: now]
      )

    :ok
  end

  defp valid_final_episode(action, %Episode{})
       when action in [:start_episode, :continue_episode, :reply],
       do: :ok

  defp valid_final_episode(action, nil) when action in [:react, :ignore], do: :ok
  defp valid_final_episode(_action, _episode), do: {:error, {:invalid_behavior_run, :episode}}

  defp transaction(callback) do
    if Repo.in_transaction?() do
      {:ok, callback.()}
    else
      Repo.transaction(callback)
    end
  end

  defp context_clauses(context) do
    [
      {:workspace, context.workspace_ref},
      {:conversation, context.conversation_ref},
      {:operator, context.operator_ref}
    ]
    |> maybe_repository(context.repository)
    |> Enum.reject(fn {_kind, ref} -> is_nil(ref) end)
  end

  defp home_behavior_visible?(
         %Behavior{scope_kind: :operator, scope_ref: actor_ref},
         actor_ref
       ),
       do: true

  defp home_behavior_visible?(%Behavior{kind: :guidance} = behavior, _actor_ref),
    do:
      behavior.scope_kind in [:repository, :workspace] and
        behavior.payload["visibility"] == "workspace"

  defp home_behavior_visible?(%Behavior{} = behavior, _actor_ref),
    do: behavior.scope_kind in [:repository, :workspace]

  defp maybe_repository(clauses, nil), do: clauses
  defp maybe_repository(clauses, repository), do: [{:repository, repository} | clauses]

  defp scope_kind("workspace"), do: :workspace
  defp scope_kind("conversation"), do: :conversation
  defp scope_kind("repository"), do: :repository
  defp scope_kind("operator"), do: :operator

  defp preference_rank(%Behavior{scope_kind: :operator}), do: 0
  defp preference_rank(%Behavior{scope_kind: :conversation}), do: 1
  defp preference_rank(%Behavior{scope_kind: :repository}), do: 2
  defp preference_rank(%Behavior{scope_kind: :workspace}), do: 3

  defp retrieval_context(context) do
    fields = [:conversation_ref, :operator_ref, :repository, :workspace_ref]

    if Map.keys(context) |> Enum.sort() == Enum.sort(fields) and
         Enum.all?([:conversation_ref, :operator_ref, :workspace_ref], fn field ->
           Reference.valid?(context[field])
         end) and (is_nil(context.repository) or Reference.valid?(context.repository)) do
      {:ok, context}
    else
      {:error, :invalid_behavior_context}
    end
  end

  defp assignment_matches?(%{"source_kind" => source_kind, "filter" => filter}, input) do
    source_kind == input.source.kind and SourceEventMatcher.matches?(filter, input.content)
  end

  defp assignment_matches?(payload, input) do
    source_matches?(payload["source_filter"], input.actor.kind) and
      event_matches?(payload["trigger"], input)
  end

  defp source_matches?("human", :user), do: true
  defp source_matches?("app", kind) when kind in [:app, :bot, :system], do: true
  defp source_matches?("any", kind) when kind in [:user, :app, :bot, :system], do: true
  defp source_matches?(_filter, _kind), do: false

  defp event_matches?(trigger, %Input{} = input) do
    explicit = explicit_event_class(input)

    explicit == trigger or
      (is_nil(explicit) and text_event_matches?(trigger, model_text(input.content)))
  end

  defp explicit_event_class(%Input{content: %{"event_class" => value}}) when is_binary(value),
    do: value

  defp explicit_event_class(%Input{
         source: %{kind: "webhook"},
         content: %{"event_type" => value}
       })
       when is_binary(value),
       do: value

  defp explicit_event_class(_input), do: nil

  defp text_event_matches?("terraform_plan", text) do
    Regex.match?(~r/\bterraform(?:\s+\w+){0,3}\s+plan\b|\bplan:\s*\d+\s+to\s+add,/iu, text)
  end

  defp text_event_matches?("deployment", text),
    do: Regex.match?(~r/\b(?:deploy(?:ed|ing|ment)?|rollout|release)\b/iu, text)

  defp text_event_matches?("operational_alert", text),
    do: Regex.match?(~r/\b(?:alert|firing|critical|degraded|unhealthy|incident)\b/iu, text)

  defp text_event_matches?(_trigger, _text), do: false

  defp model_text(content) do
    [content["text"], get_in(content, ["payload", "text"]), content["event_type"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp lock_offer(record_ref) do
    query =
      from(record in Record,
        join: episode in Episode,
        on: episode.id == record.episode_id,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where: record.ref == ^record_ref and record.kind in ^@offer_kinds,
        select: {record, episode, turn},
        lock: "FOR UPDATE"
      )

    case Repo.one(query) do
      nil -> {:error, :behavior_offer_not_found}
      {record, episode, turn} -> {:ok, record, episode, turn}
    end
  end

  defp delivered_from?(episode, turn, target) do
    case CardDelivery.delivered_from?(episode, turn, target) do
      :ok -> :ok
      {:error, :mismatch} -> {:error, :behavior_offer_delivery_mismatch}
      {:error, :not_delivered} -> {:error, :behavior_offer_not_delivered}
    end
  end

  defp expires_at(confirmed_at, "7d"), do: DateTime.add(confirmed_at, 7, :day)
  defp expires_at(confirmed_at, "30d"), do: DateTime.add(confirmed_at, 30, :day)
  defp expires_at(confirmed_at, "90d"), do: DateTime.add(confirmed_at, 90, :day)
  defp expires_at(confirmed_at, "365d"), do: DateTime.add(confirmed_at, 365, :day)

  defp source_event_expiry(nil, _confirmed_at), do: {:ok, nil}

  defp source_event_expiry(value, confirmed_at) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, 0} ->
        if DateTime.compare(expires_at, confirmed_at) == :gt,
          do: {:ok, expires_at},
          else: {:error, :behavior_expiry_elapsed}

      _invalid ->
        {:error, :behavior_expiry_invalid}
    end
  end

  defp source_event_expiry(_value, _confirmed_at), do: {:error, :behavior_expiry_invalid}

  defp source_event_identity(payload) do
    "source-event:" <> CanonicalJSON.digest([payload["title"]])
  end

  defp confirmation_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> confirmation_attributes(),
       else: {:error, {:invalid_behavior_confirmation, :fields}}
  end

  defp confirmation_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@confirmation_fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_behavior_confirmation, :fields}}
  end

  defp confirmation_attributes(_attributes),
    do: {:error, {:invalid_behavior_confirmation, :fields}}

  defp target(%{} = target) do
    if Map.keys(target) |> Enum.sort() == Enum.sort(@target_fields) do
      with :ok <- reference(target.transport, :transport),
           :ok <- reference(target.conversation_ref, :conversation_ref),
           :ok <- optional_reference(target.thread_ref, :thread_ref),
           :ok <- reference(target.message_ref, :message_ref) do
        {:ok, target}
      end
    else
      {:error, {:invalid_behavior_confirmation, :target}}
    end
  end

  defp target(_target), do: {:error, {:invalid_behavior_confirmation, :target}}

  defp utc_datetime(%DateTime{} = value, _field) do
    case UTCDateTime.exact(value) do
      {:ok, exact} -> {:ok, exact}
      :error -> {:error, {:invalid_behavior_confirmation, :datetime}}
    end
  end

  defp utc_datetime(_value, field), do: {:error, {:invalid_behavior_confirmation, field}}

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if Reference.valid?(value), do: :ok, else: {:error, {:invalid_behavior_confirmation, field}}
  end
end
