defmodule Responder.State.Behaviors do
  @moduledoc """
  Operator-confirmed durable behavior and guidance.

  Model tools may create inert offers only. This module rechecks the delivered
  control, derives scope from host-owned identity and destination, supersedes
  one exact logical entry, and exposes bounded retrieval. None of these records
  can widen Work, publication, or delivery authority.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes.Episode
  alias Responder.Ingress.Input
  alias Responder.Repo
  alias Responder.Slack.ChannelFence

  alias Responder.State.{
    Behavior,
    BehaviorChangeset,
    Record,
    RecordChangeset,
    StandingAssignmentRun,
    StandingAssignmentRunChangeset
  }

  alias Responder.Work.Turn

  @confirmation_fields [:actor_ref, :confirmation_ref, :occurred_at, :record_ref, :target]
  @target_fields [:conversation_ref, :message_ref, :thread_ref, :transport]
  @offer_kinds ~w(preference_offer guidance_offer standing_assignment_offer)
  @maximum_total 500
  @maximum_per_scope 100
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
      |> transaction_result()
    end
  end

  @spec set_status(String.t(), :active | :disabled | :deleted) ::
          {:ok, Behavior.t()} | {:error, term()}
  def set_status(ref, status) when status in [:active, :disabled, :deleted] do
    with :ok <- reference(ref, :behavior_ref) do
      Repo.transaction(fn -> set_status_locked(ref, status, nil) end)
      |> transaction_result()
    end
  end

  def set_status(_ref, _status), do: {:error, {:invalid_behavior, :status}}

  @spec set_status(String.t(), :active | :disabled | :deleted, String.t()) ::
          {:ok, Behavior.t()} | {:error, term()}
  def set_status(ref, status, workspace_ref) when status in [:active, :disabled, :deleted] do
    with :ok <- reference(ref, :behavior_ref),
         :ok <- reference(workspace_ref, :workspace_ref) do
      Repo.transaction(fn -> set_status_locked(ref, status, workspace_ref) end)
      |> transaction_result()
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
      |> transaction_result()
    end
  end

  def set_home_status(_ref, _status, _actor_ref, _workspace_ref),
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

  defp set_visible_home_status(behavior, ref, status, actor_ref, workspace_ref) do
    if home_behavior_visible?(behavior, actor_ref),
      do: set_status_locked(ref, status, workspace_ref),
      else: Repo.rollback(:behavior_unauthorized)
  end

  @spec assignments_for_channel(String.t(), String.t()) :: [Behavior.t()]
  def assignments_for_channel(workspace_ref, conversation_ref) do
    if reference_value?(workspace_ref) and reference_value?(conversation_ref) do
      now = database_now!()

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
      |> transaction_result()
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
      workspace_ref:
        workspace_ref(episode.destination_transport, episode.destination_conversation_ref)
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
    case retrieval_context(context) do
      {:ok, context} ->
        active_for_context(:guidance, context)
        |> Enum.filter(fn behavior ->
          guidance_scope?(behavior, scope, context) and
            behavior
            |> guidance_document()
            |> CanonicalJSON.encode!()
            |> String.downcase()
            |> String.contains?(String.downcase(query))
        end)
        |> Enum.take(limit)
        |> account_guidance()

      {:error, _reason} ->
        []
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
    ids = Enum.map(behaviors, & &1.id)
    now = database_now!()

    Repo.update_all(from(behavior in Behavior, where: behavior.id in ^ids),
      inc: [use_count: 1],
      set: [last_used_at: now]
    )

    Enum.map(behaviors, &guidance_document/1)
  end

  defp guidance_document(behavior) do
    %{
      "behavior_ref" => behavior.ref,
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

  defp guidance_scope?(
         %Behavior{scope_kind: :conversation, scope_ref: ref},
         "current_channel",
         context
       ),
       do: ref == context.conversation_ref

  defp guidance_scope?(%Behavior{scope_kind: :repository, scope_ref: ref}, "repository", context),
    do: ref == context.repository

  defp guidance_scope?(%Behavior{scope_kind: :workspace, scope_ref: ref}, "workspace", context),
    do: ref == context.workspace_ref

  defp guidance_scope?(%Behavior{scope_kind: :operator, scope_ref: ref}, "mine", context),
    do: ref == context.operator_ref

  defp guidance_scope?(_behavior, _scope, _context), do: false

  @doc "Returns true only when an active channel assignment matches trusted source identity and event shape."
  @spec standing_match?(Input.t()) :: boolean()
  def standing_match?(%Input{} = input), do: matching_assignments(input, false) != []

  def standing_match?(_input), do: false

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

    if reference_value?(workspace_ref) and (is_nil(status) or status in @statuses) and
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
    workspace = workspace_ref(episode.destination_transport, episode.destination_conversation_ref)

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
    workspace = workspace_ref(episode.destination_transport, episode.destination_conversation_ref)

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
    workspace = workspace_ref(episode.destination_transport, episode.destination_conversation_ref)
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
    now = database_now!()

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
        set: [status: :superseded, updated_at: database_now!()],
        inc: [revision: 1]
      )

    :ok
  end

  defp insert_behavior(record, episode, attributes, prepared) do
    id = Ecto.UUID.generate()

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
      source_thread_ref: episode.destination_thread_ref,
      source_transport: episode.destination_transport,
      status: :active
    })
    |> BehaviorChangeset.insert()
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
    now = database_now!()

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
    now = database_now!()
    workspace = workspace_ref(input.destination.transport, input.destination.conversation_ref)

    query =
      from(behavior in Behavior,
        where:
          behavior.kind == :standing_assignment and behavior.status == :active and
            behavior.workspace_ref == ^workspace and behavior.scope_kind == :conversation and
            behavior.scope_ref == ^input.destination.conversation_ref and
            (is_nil(behavior.expires_at) or behavior.expires_at > ^now),
        order_by: [asc: behavior.inserted_at],
        limit: 100
      )

    query = if lock?, do: from(behavior in query, lock: "FOR SHARE"), else: query

    query
    |> Repo.all()
    |> Enum.filter(&assignment_matches?(&1.payload, input))
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
    now = database_now!()
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
      |> transaction_result()
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
           reference_value?(context[field])
         end) and (is_nil(context.repository) or reference_value?(context.repository)) do
      {:ok, context}
    else
      {:error, :invalid_behavior_context}
    end
  end

  defp assignment_matches?(%{"source_kind" => source_kind, "filter" => filter}, input) do
    source_kind == input.source.kind and partial_match?(filter, input.content)
  end

  defp assignment_matches?(payload, input) do
    source_matches?(payload["source_filter"], input.actor.kind) and
      event_matches?(payload["trigger"], input)
  end

  defp partial_match?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {key, value} ->
      case Map.fetch(actual, key) do
        {:ok, actual_value} -> partial_match?(value, actual_value)
        :error -> false
      end
    end)
  end

  defp partial_match?(expected, actual), do: expected == actual

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

  defp delivered_from?(episode, %Turn{status: :settled, external_receipt: receipt}, target)
       when is_map(receipt) do
    expected = %{
      conversation_ref: episode.destination_conversation_ref,
      message_ref: receipt["message_ref"],
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }

    if expected == target,
      do: :ok,
      else: {:error, :behavior_offer_delivery_mismatch}
  end

  defp delivered_from?(_episode, _turn, _target),
    do: {:error, :behavior_offer_not_delivered}

  defp workspace_ref("slack", conversation_ref) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", workspace_ref, _channel_ref] -> "slack:#{workspace_ref}"
      _invalid -> conversation_ref
    end
  end

  defp workspace_ref("github", conversation_ref) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["github", binding_ref, _rest] -> "github:#{binding_ref}"
      _invalid -> conversation_ref
    end
  end

  defp workspace_ref(_transport, conversation_ref), do: conversation_ref

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
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      {microsecond, _precision} = value.microsecond
      {:ok, %{value | microsecond: {microsecond, 6}}}
    else
      {:error, {:invalid_behavior_confirmation, :datetime}}
    end
  end

  defp utc_datetime(_value, field), do: {:error, {:invalid_behavior_confirmation, field}}

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if reference_value?(value),
      do: :ok,
      else: {:error, {:invalid_behavior_confirmation, field}}
  end

  defp reference_value?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  defp database_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
