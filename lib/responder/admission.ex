defmodule Responder.Admission do
  @moduledoc """
  Builds and validates one source-neutral admission decision.

  It uses conversation, thread, episode state, and age to bound the choices the
  model may make. It never searches for provider names or status phrases.
  """

  import Ecto.Query

  alias Responder.Admission.{Candidate, Context, Decision}
  alias Responder.Episodes
  alias Responder.Episodes.{Command, ConversationLock, Episode, Event}
  alias Responder.Ingress.{Inbox, Input}
  alias Responder.Ingress.Inbox.{Entry, EntryChangeset}
  alias Responder.Repo

  @active_states [:working, :waiting_for_input, :waiting_for_event]

  @spec context(String.t(), keyword()) :: {:ok, Context.t()} | {:error, term()}
  def context(input_ref, options) do
    with {:ok, settings} <- validate_options(options),
         {:ok, entry} <- Inbox.fetch(input_ref),
         :ok <- pending(entry),
         :ok <- lease_owned(entry, settings.lease_ref),
         {:ok, input} <- input_from_entry(entry) do
      snapshot_context(input, entry, settings)
    end
  end

  @doc false
  @spec restore_context(Entry.t(), String.t()) :: {:ok, Context.t()} | {:error, term()}
  def restore_context(%Entry{} = entry, lease_ref) do
    with :ok <- pending(entry),
         :ok <- lease_owned(entry, lease_ref),
         {:ok, input} <- input_from_entry(entry),
         snapshot when is_map(snapshot) <- entry.admission_context,
         {:ok, episode_ids} <- Context.episode_ids(snapshot),
         episodes <- episodes_by_id(episode_ids),
         {:ok, context} <- Context.restore(snapshot, input, entry, episodes) do
      {:ok, context}
    else
      nil -> {:error, {:invalid_admission_context_snapshot, :missing}}
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_admission_context_snapshot, :document}}
    end
  end

  def restore_context(_entry, _lease_ref),
    do: {:error, {:invalid_admission_context_snapshot, :entry}}

  defp snapshot_context(input, entry, settings) do
    nested? = Repo.in_transaction?()

    Repo.transaction(fn ->
      case ensure_snapshot_isolation(nested?) do
        :ok -> build_context_locked(input, entry, settings)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> transaction_result()
  end

  defp ensure_snapshot_isolation(false) do
    case Repo.query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ") do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:store_failed, :context_isolation, reason}}
    end
  end

  defp ensure_snapshot_isolation(true) do
    case Repo.query("SHOW transaction_isolation") do
      {:ok, %{rows: [["repeatable read"]]}} -> :ok
      {:ok, %{rows: [[isolation]]}} -> {:error, {:unsafe_context_isolation, isolation}}
      {:error, reason} -> {:error, {:store_failed, :context_isolation, reason}}
    end
  end

  defp build_context_locked(input, entry, settings) do
    with :ok <- lock_conversation(input),
         {:ok, candidates} <- candidates(input, settings) do
      %Context{
        active_episode_fingerprint: active_episode_fingerprint_for_destination(input.destination),
        built_at: settings.now,
        candidates: candidates,
        conversation_episode_count: conversation_episode_count(input),
        input: input,
        input_entry: entry
      }
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec validate(Context.t(), Decision.t()) ::
          {:ok, %{candidate: Candidate.t() | nil, decision: Decision.t()}} | {:error, term()}
  def validate(%Context{} = context, decision) do
    with {:ok, decision} <- Decision.prepare(decision),
         :ok <- allowed_action(context.input, decision.action),
         {:ok, candidate} <- selected_candidate(context, decision.episode_ref),
         :ok <- allowed_relation(candidate, decision.relation),
         :ok <- source_owner_selection(context, candidate, decision) do
      {:ok, %{candidate: candidate, decision: decision}}
    end
  end

  def validate(_context, _decision), do: {:error, {:admission_rejected, :context}}

  defp source_owner_selection(context, candidate, decision) do
    case source_owner_candidate(context) do
      {owner, revision}
      when revision < context.input.revision and
             decision.action in [:start_episode, :continue_episode, :reply] ->
        if valid_source_owner_selection?(owner, candidate, decision),
          do: :ok,
          else: {:error, {:admission_rejected, :source_item_owner, owner_ref: owner.ref}}

      _no_required_owner ->
        :ok
    end
  end

  defp valid_source_owner_selection?(
         %Candidate{episode: %{state: :cancelled}} = owner,
         candidate,
         decision
       ) do
    candidate == owner and decision.relation == :history_only
  end

  defp valid_source_owner_selection?(owner, candidate, decision) do
    candidate == owner and decision.relation == :same_work
  end

  defp source_owner_candidate(context) do
    context.candidates
    |> Enum.flat_map(fn candidate ->
      case Map.fetch(candidate.episode.input_revisions, context.input.native_input_id) do
        {:ok, revision} -> [{candidate, revision}]
        :error -> []
      end
    end)
    |> Enum.max_by(fn {_candidate, revision} -> revision end, fn -> nil end)
  end

  @type commit_result :: %{
          entry: Entry.t(),
          episode: Episode.t() | nil,
          status: :applied | :duplicate | :superseded,
          transitions: [Responder.Episodes.Transition.t()]
        }

  @spec commit(Context.t(), Decision.t(), String.t()) ::
          {:ok, commit_result()} | {:error, term()}
  def commit(context, decision, decision_ref), do: commit(context, decision, decision_ref, [])

  @spec commit(Context.t(), Decision.t(), String.t(), keyword()) ::
          {:ok, commit_result()} | {:error, term()}
  def commit(%Context{} = context, decision, decision_ref, options) do
    with {:ok, lease_ref} <- commit_options(options),
         {:ok, decision} <- Decision.prepare(decision),
         :ok <- validate_reference(decision_ref) do
      Repo.transaction(fn ->
        commit_in_transaction(context, decision, decision_ref, lease_ref)
      end)
      |> transaction_result()
    end
  end

  def commit(_context, _decision, _decision_ref, _options),
    do: {:error, {:admission_rejected, :context}}

  defp commit_in_transaction(context, decision, decision_ref, lease_ref) do
    with {:ok, entry} <- load_entry(context.input_entry.id),
         {:ok, result} <- commit_locked(entry, context, decision, decision_ref, lease_ref) do
      result
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_options(options) when is_list(options) do
    now = Keyword.get(options, :now)
    continuation_window = Keyword.get(options, :continuation_window)
    history_window = Keyword.get(options, :history_window)
    candidate_limit = Keyword.get(options, :candidate_limit, 20)
    lease_ref = Keyword.get(options, :lease_ref)

    with :ok <- context_option_keys(options),
         :ok <- context_value(utc_datetime?(now), :now),
         :ok <- context_value(positive_integer?(continuation_window), :continuation_window),
         :ok <- valid_history_window(history_window, continuation_window),
         :ok <- valid_candidate_limit(candidate_limit),
         :ok <- context_value(valid_optional_reference?(lease_ref), :lease_ref) do
      {:ok,
       %{
         candidate_limit: candidate_limit,
         continuation_window: continuation_window,
         history_window: history_window,
         lease_ref: lease_ref,
         now: now
       }}
    end
  end

  defp validate_options(_options), do: {:error, {:invalid_admission_context, :options}}

  defp context_option_keys(options) do
    allowed = [:candidate_limit, :continuation_window, :history_window, :lease_ref, :now]

    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) -- allowed == [],
       do: :ok,
       else: {:error, {:invalid_admission_context, :options}}
  end

  defp valid_history_window(history_window, continuation_window) do
    context_value(
      positive_integer?(history_window) and history_window >= continuation_window,
      :history_window
    )
  end

  defp valid_candidate_limit(value) do
    context_value(is_integer(value) and value >= 1 and value <= 20, :candidate_limit)
  end

  defp context_value(true, _field), do: :ok
  defp context_value(false, field), do: {:error, {:invalid_admission_context, field}}

  defp pending(%{status: :pending}), do: :ok

  defp pending(%{status: :decided, decision_ref: decision_ref}),
    do: {:error, {:input_already_decided, decision_ref}}

  defp pending(%{status: :superseded, decision_ref: decision_ref}),
    do: {:error, {:input_already_superseded, decision_ref}}

  defp pending(%{
         status: :blocked,
         last_error_code: error_code,
         last_error_detail: error_detail
       }),
       do: {:error, {:input_blocked, error_code, error_detail}}

  defp lease_owned(%Entry{lease_ref: nil}, nil), do: :ok
  defp lease_owned(%Entry{lease_ref: lease_ref}, lease_ref) when is_binary(lease_ref), do: :ok
  defp lease_owned(_entry, _lease_ref), do: {:error, {:admission_rejected, :lease_lost}}

  defp input_from_entry(entry) do
    Input.new(%{
      actor: %{kind: entry.actor_kind, ref: entry.actor_ref},
      can_react: entry.can_react,
      content: entry.content,
      destination: %{
        conversation_ref: entry.destination_conversation_ref,
        thread_ref: entry.destination_thread_ref,
        transport: entry.destination_transport
      },
      event_kind: entry.event_kind,
      event_ref: entry.event_ref,
      native_input_id: entry.native_input_id,
      occurred_at: entry.occurred_at,
      occurred_at_source: entry.occurred_at_source,
      revision: entry.revision,
      source: %{kind: entry.source_kind, ref: entry.source_ref},
      source_item_ref: entry.source_item_ref
    })
  end

  defp load_entry(id) do
    case Repo.one(from(entry in Entry, where: entry.id == ^id, lock: "FOR UPDATE")) do
      nil -> {:error, {:admission_rejected, :input_not_found}}
      entry -> {:ok, entry}
    end
  end

  defp episodes_by_id([]), do: %{}

  defp episodes_by_id(ids) do
    Repo.all(from(episode in Episode, where: episode.id in ^ids))
    |> Map.new(&{&1.id, &1})
  end

  defp commit_locked(
         %Entry{status: status} = entry,
         _context,
         decision,
         decision_ref,
         _lease_ref
       )
       when status in [:decided, :superseded] do
    submitted = Decision.fingerprint(decision)

    if entry.decision_ref == decision_ref and entry.decision_fingerprint == submitted do
      {:ok,
       %{
         entry: entry,
         episode: load_decided_episode(entry.episode_id),
         status: if(status == :superseded, do: :superseded, else: :duplicate),
         transitions: []
       }}
    else
      {:error,
       {:decision_conflict,
        input_ref: Inbox.ref(entry),
        stored_decision_ref: entry.decision_ref,
        submitted_decision_ref: decision_ref,
        stored_fingerprint: entry.decision_fingerprint,
        submitted_fingerprint: submitted}}
    end
  end

  defp commit_locked(
         %Entry{
           status: :blocked,
           last_error_code: error_code,
           last_error_detail: error_detail
         },
         _context,
         _decision,
         _decision_ref,
         _lease_ref
       ),
       do: {:error, {:input_blocked, error_code, error_detail}}

  defp commit_locked(
         %Entry{status: :pending} = entry,
         context,
         decision,
         decision_ref,
         lease_ref
       ) do
    with :ok <- same_input(entry, context),
         :ok <- lease_owned(entry, lease_ref),
         {:ok, selection} <- validate(context, decision),
         {:ok, selection, source_owner} <- current_routing_scope(context, selection) do
      apply_and_persist(context, entry, selection, decision, decision_ref, source_owner)
    end
  end

  defp apply_and_persist(
         context,
         entry,
         selection,
         decision,
         decision_ref,
         source_owner
       ) do
    case source_owner do
      {episode, latest} when latest >= context.input.revision ->
        details = [
          native_input_id: context.input.native_input_id,
          submitted: context.input.revision,
          latest: latest
        ]

        persist_superseded(entry, decision, decision_ref, episode, details)

      {%Episode{} = owner, _earlier_revision} ->
        if source_owner_matches_selection?(owner, selection) do
          apply_and_persist_current(context, entry, selection, decision, decision_ref)
        else
          {:error, {:admission_rejected, :context_stale}}
        end

      nil ->
        apply_and_persist_current(context, entry, selection, decision, decision_ref)
    end
  end

  defp source_owner_matches_selection?(owner, selection) do
    case selection.decision.action do
      action when action in [:start_episode, :continue_episode, :reply] ->
        source_owner_routing_matches?(owner, selection)

      _non_routing_action ->
        true
    end
  end

  defp source_owner_routing_matches?(%Episode{state: :cancelled, id: id}, selection) do
    match?(%Candidate{episode: %Episode{id: ^id}}, selection.candidate) and
      selection.decision.relation == :history_only
  end

  defp source_owner_routing_matches?(%Episode{id: id}, selection) do
    match?(%Episode{id: ^id}, existing_episode(selection))
  end

  defp apply_and_persist_current(context, entry, selection, decision, decision_ref) do
    case apply_episode(context, entry, selection) do
      {:ok, transitions, episode} ->
        with {:ok, decided} <- persist_decision(entry, decision, decision_ref, episode) do
          {:ok, %{entry: decided, episode: episode, status: :applied, transitions: transitions}}
        end

      {:error, {:stale_input_revision, details} = reason} ->
        supersede_stale_revision(entry, selection, decision, decision_ref, details, reason)

      {:error, _reason} = error ->
        error
    end
  end

  defp supersede_stale_revision(entry, selection, decision, decision_ref, details, reason) do
    case existing_episode(selection) do
      %Episode{} = episode ->
        persist_superseded(entry, decision, decision_ref, episode, details)

      nil ->
        {:error, reason}
    end
  end

  defp persist_superseded(entry, decision, decision_ref, episode, details) do
    with {:ok, decided} <-
           persist_superseded_decision(entry, decision, decision_ref, episode, details) do
      {:ok, %{entry: decided, episode: episode, status: :superseded, transitions: []}}
    end
  end

  defp current_source_owner(context) do
    native_input_id = context.input.native_input_id
    destination = context.input.destination

    case Repo.one(
           from(episode in Episode,
             where:
               episode.destination_transport == ^destination.transport and
                 episode.destination_conversation_ref == ^destination.conversation_ref and
                 fragment("(? ->> ?) IS NOT NULL", episode.input_revisions, ^native_input_id),
             order_by: [
               desc:
                 fragment(
                   "CAST((? ->> ?) AS bigint)",
                   episode.input_revisions,
                   ^native_input_id
                 ),
               asc: episode.id
             ],
             limit: 1
           )
         ) do
      nil -> nil
      episode -> {episode, Map.fetch!(episode.input_revisions, native_input_id)}
    end
  end

  defp current_routing_scope(%Context{} = context, selection) do
    with :ok <- lock_conversation(context.input),
         :ok <- compare_routing_generation(context, selection) do
      {:ok, refresh_selection(selection), current_source_owner(context)}
    end
  end

  defp compare_routing_generation(context, selection) do
    if routes_episode?(selection) and creates_episode?(selection),
      do: compare_conversation_generation(context),
      else: :ok
  end

  defp compare_conversation_generation(context) do
    same_count? = conversation_episode_count(context.input) == context.conversation_episode_count

    same_active? =
      active_episode_fingerprint_for_destination(context.input.destination) ==
        context.active_episode_fingerprint

    if same_count? and same_active?,
      do: :ok,
      else: {:error, {:admission_rejected, :context_stale}}
  end

  defp refresh_selection(%{candidate: nil} = selection), do: selection

  defp refresh_selection(%{candidate: candidate} = selection) do
    current = Repo.get(Episode, candidate.episode.id)

    if current,
      do: %{selection | candidate: %{candidate | episode: current}},
      else: selection
  end

  defp routes_episode?(%{decision: %{action: action}})
       when action in [:start_episode, :continue_episode, :reply],
       do: true

  defp routes_episode?(_selection), do: false

  defp creates_episode?(%{decision: %{action: action}} = selection)
       when action in [:start_episode, :reply],
       do: is_nil(existing_episode(selection))

  defp creates_episode?(_selection), do: false

  defp lock_conversation(input) do
    ConversationLock.lock(Repo, input.destination)
  end

  defp same_input(entry, context) do
    expected = context.input_entry

    cond do
      entry.id != expected.id ->
        {:error, {:admission_rejected, :input_changed}}

      entry.event_fingerprint != expected.event_fingerprint ->
        {:error, {:admission_rejected, :input_changed}}

      Input.fingerprint(context.input) != entry.event_fingerprint ->
        {:error, {:admission_rejected, :input_changed}}

      true ->
        :ok
    end
  end

  defp apply_episode(_context, _entry, %{decision: %{action: action}})
       when action in [:ignore, :react],
       do: {:ok, [], nil}

  defp apply_episode(context, entry, selection) do
    admit = admit_command(context, entry, selection)
    existing = existing_episode(selection)

    with {:ok, [admitted]} <- apply_admit(admit, existing),
         {:ok, resumed} <- maybe_resume_wait(context, selection, admit, admitted.episode) do
      transitions = [admitted | resumed]
      {:ok, transitions, transitions |> List.last() |> Map.fetch!(:episode)}
    end
  end

  defp apply_admit(admit, %Episode{}), do: Episodes.apply_batch_in_transaction([admit])

  defp apply_admit(admit, nil), do: Episodes.apply_batch_in_transaction([admit])

  defp admit_command(context, entry, selection) do
    existing = existing_episode(selection)
    input = context.input
    turn_ref = "ingress-turn:#{entry.id}"

    %Command.AdmitInput{
      actor_ref: Input.actor_ref(input),
      destination: target_destination(input, existing),
      episode_id: if(existing, do: existing.id, else: entry.id),
      episode_key: if(existing, do: existing.key, else: "ingress-input:#{entry.id}"),
      linked_episode_id: linked_episode(selection, existing),
      native_input_id: input.native_input_id,
      occurred_at: input.occurred_at,
      payload: Input.document(input),
      revision: input.revision,
      turn_ref: turn_ref
    }
  end

  defp maybe_resume_wait(context, selection, admit, current) do
    existing = existing_episode(selection)

    if existing && waiting?(current) && input_after_wait?(current, context.input.occurred_at) do
      resume = %Command.ResumeWait{
        episode_key: current.key,
        expected_wait: %{kind: current.owner_kind, ref: current.owner_ref},
        occurred_at: context.input.occurred_at,
        resolution_ref: Command.dedupe_key(admit),
        turn_ref: admit.turn_ref
      }

      Episodes.apply_batch_in_transaction([resume])
    else
      {:ok, []}
    end
  end

  defp existing_episode(%{candidate: %Candidate{} = candidate, decision: decision}) do
    if decision.relation == :same_work, do: candidate.episode, else: nil
  end

  defp existing_episode(_selection), do: nil

  defp target_destination(_input, %Episode{} = episode) do
    %{
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }
  end

  defp target_destination(input, nil), do: input.destination

  defp linked_episode(_selection, %Episode{} = episode), do: episode.linked_episode_id

  defp linked_episode(%{candidate: %Candidate{} = candidate, decision: decision}, nil) do
    if decision.relation == :history_only, do: candidate.episode.id, else: nil
  end

  defp linked_episode(_selection, nil), do: nil

  defp waiting?(%Episode{state: state}) when state in [:waiting_for_input, :waiting_for_event],
    do: true

  defp waiting?(_episode), do: false

  defp input_after_wait?(%Episode{} = episode, occurred_at) do
    wait_kinds = [:input_wait_started, :event_wait_started]

    case Repo.one(
           from(event in Event,
             where: event.episode_id == ^episode.id and event.kind in ^wait_kinds,
             order_by: [desc: event.sequence],
             limit: 1
           )
         ) do
      nil -> false
      event -> DateTime.compare(occurred_at, event.occurred_at) == :gt
    end
  end

  defp persist_decision(entry, decision, decision_ref, episode) do
    entry
    |> EntryChangeset.decide(decision, decision_ref, episode && episode.id)
    |> Repo.update()
    |> case do
      {:ok, decided} ->
        {:ok, decided}

      {:error, changeset} ->
        {:error, {:persistence_failed, :admission_decision, changeset.errors}}
    end
  end

  defp persist_superseded_decision(entry, decision, decision_ref, episode, details) do
    entry
    |> EntryChangeset.supersede(decision, decision_ref, episode.id, details)
    |> Repo.update()
    |> case do
      {:ok, decided} ->
        {:ok, decided}

      {:error, changeset} ->
        {:error, {:persistence_failed, :admission_decision, changeset.errors}}
    end
  end

  defp load_decided_episode(nil), do: nil
  defp load_decided_episode(id), do: Repo.get(Episode, id)

  defp candidates(input, settings) do
    with :ok <-
           required_candidates_fit(
             input.destination,
             input.native_input_id,
             settings.candidate_limit
           ) do
      destination = input.destination
      history_cutoff = DateTime.add(settings.now, -settings.history_window, :second)

      episodes =
        Repo.all(
          candidate_query(
            destination,
            input.native_input_id,
            history_cutoff,
            settings.candidate_limit
          )
        )

      endpoints_by_episode = input_event_endpoints(Enum.map(episodes, & &1.id))

      {:ok,
       Enum.map(episodes, fn episode ->
         episode
         |> Candidate.new(
           Map.get(endpoints_by_episode, episode.id, %{}),
           destination.thread_ref,
           settings.now,
           settings.continuation_window
         )
         |> require_same_work_for_newer_revision(input)
       end)}
    end
  end

  defp require_same_work_for_newer_revision(candidate, input) do
    case Map.fetch(candidate.episode.input_revisions, input.native_input_id) do
      {:ok, revision}
      when revision < input.revision and candidate.episode.state != :cancelled ->
        %{candidate | allowed_relations: [:same_work, :history_only]}

      _not_a_newer_revision ->
        candidate
    end
  end

  defp required_candidates_fit(destination, native_input_id, candidate_limit) do
    required = required_candidate_count(destination, native_input_id)

    if required <= candidate_limit,
      do: :ok,
      else: {:error, {:admission_context_overflow, required: required, limit: candidate_limit}}
  end

  defp required_candidate_count(%{thread_ref: nil} = destination, native_input_id) do
    Repo.aggregate(
      from(episode in Episode,
        where:
          episode.destination_transport == ^destination.transport and
            episode.destination_conversation_ref == ^destination.conversation_ref and
            (episode.state in ^@active_states or
               fragment("(? ->> ?) IS NOT NULL", episode.input_revisions, ^native_input_id))
      ),
      :count
    )
  end

  defp required_candidate_count(destination, native_input_id) do
    exact_thread =
      from(episode in Episode,
        where:
          episode.destination_transport == ^destination.transport and
            episode.destination_conversation_ref == ^destination.conversation_ref and
            episode.destination_thread_ref == ^destination.thread_ref
      )

    active_exact_thread =
      Repo.aggregate(
        from(episode in exact_thread,
          where:
            episode.state in ^@active_states or
              fragment("(? ->> ?) IS NOT NULL", episode.input_revisions, ^native_input_id)
        ),
        :count
      )

    owned_elsewhere =
      Repo.aggregate(
        from(episode in Episode,
          where:
            episode.destination_transport == ^destination.transport and
              episode.destination_conversation_ref == ^destination.conversation_ref and
              (is_nil(episode.destination_thread_ref) or
                 episode.destination_thread_ref != ^destination.thread_ref) and
              fragment("(? ->> ?) IS NOT NULL", episode.input_revisions, ^native_input_id)
        ),
        :count
      )

    if Repo.exists?(exact_thread),
      do: active_exact_thread + owned_elsewhere,
      else: required_candidate_count(%{destination | thread_ref: nil}, native_input_id)
  end

  defp candidate_query(
         %{thread_ref: nil} = destination,
         native_input_id,
         history_cutoff,
         candidate_limit
       ) do
    from(episode in Episode,
      where:
        episode.destination_transport == ^destination.transport and
          episode.destination_conversation_ref == ^destination.conversation_ref,
      where:
        episode.state in ^@active_states or episode.updated_at >= ^history_cutoff or
          fragment("(? ->> ?) IS NOT NULL", episode.input_revisions, ^native_input_id),
      order_by: [
        desc: fragment("(? ->> ?) IS NOT NULL", episode.input_revisions, ^native_input_id),
        desc: episode.state in ^@active_states,
        desc: episode.updated_at,
        asc: episode.id
      ],
      limit: ^candidate_limit
    )
  end

  defp candidate_query(destination, native_input_id, history_cutoff, candidate_limit) do
    from(episode in Episode,
      where:
        episode.destination_transport == ^destination.transport and
          episode.destination_conversation_ref == ^destination.conversation_ref,
      where:
        episode.destination_thread_ref == ^destination.thread_ref or
          episode.state in ^@active_states or episode.updated_at >= ^history_cutoff or
          fragment("(? ->> ?) IS NOT NULL", episode.input_revisions, ^native_input_id),
      order_by: [
        desc: fragment("(? ->> ?) IS NOT NULL", episode.input_revisions, ^native_input_id),
        desc: fragment("? = ?", episode.destination_thread_ref, ^destination.thread_ref),
        desc: episode.state in ^@active_states,
        desc: episode.updated_at,
        asc: episode.id
      ],
      limit: ^candidate_limit
    )
  end

  defp conversation_episode_count(input) do
    destination = input.destination

    Repo.aggregate(
      from(episode in Episode,
        where:
          episode.destination_transport == ^destination.transport and
            episode.destination_conversation_ref == ^destination.conversation_ref
      ),
      :count
    )
  end

  defp current_active_episode_ids(destination) do
    Repo.all(
      from(episode in Episode,
        where:
          episode.destination_transport == ^destination.transport and
            episode.destination_conversation_ref == ^destination.conversation_ref and
            episode.state in ^@active_states,
        order_by: [asc: episode.id],
        select: episode.id
      )
    )
  end

  defp active_episode_fingerprint_for_destination(destination) do
    destination
    |> current_active_episode_ids()
    |> Responder.CanonicalJSON.digest()
  end

  @doc false
  @spec input_event_endpoints([Ecto.UUID.t()]) :: map()
  def input_event_endpoints([]), do: %{}

  def input_event_endpoints(episode_ids) do
    first = endpoint_rows(episode_ids, :first)
    latest = endpoint_rows(episode_ids, :latest)

    Enum.reduce(first ++ latest, %{}, fn {position, row}, endpoints ->
      Map.update(endpoints, row.episode_id, %{position => row}, &Map.put(&1, position, row))
    end)
  end

  defp endpoint_rows(episode_ids, :first) do
    Enum.map(episode_ids, &endpoint_row(&1, :first))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{:first, &1})
  end

  defp endpoint_rows(episode_ids, :latest) do
    Enum.map(episode_ids, &endpoint_row(&1, :latest))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&{:latest, &1})
  end

  defp endpoint_row(episode_id, :first) do
    Repo.one(
      from(event in Event,
        where: event.episode_id == ^episode_id and event.kind == :input_admitted,
        order_by: [asc: event.occurred_at, asc: event.sequence],
        limit: 1,
        select: %{
          episode_id: event.episode_id,
          occurred_at: event.occurred_at,
          payload: event.payload
        }
      )
    )
  end

  defp endpoint_row(episode_id, :latest) do
    Repo.one(
      from(event in Event,
        where: event.episode_id == ^episode_id and event.kind == :input_admitted,
        order_by: [desc: event.occurred_at, desc: event.sequence],
        limit: 1,
        select: %{
          episode_id: event.episode_id,
          occurred_at: event.occurred_at,
          payload: event.payload
        }
      )
    )
  end

  defp selected_candidate(_context, nil), do: {:ok, nil}

  defp selected_candidate(%Context{} = context, ref) do
    case Enum.find(context.candidates, &(&1.ref == ref)) do
      nil -> {:error, {:admission_rejected, :unknown_candidate}}
      candidate -> {:ok, candidate}
    end
  end

  defp allowed_action(input, action) do
    if action in Input.allowed_actions(input),
      do: :ok,
      else: {:error, {:admission_rejected, :action_not_allowed, submitted: action}}
  end

  defp allowed_relation(nil, :unrelated), do: :ok

  defp allowed_relation(%Candidate{} = candidate, relation) do
    if relation in candidate.allowed_relations do
      :ok
    else
      {:error,
       {:admission_rejected, :relation_not_allowed,
        allowed: candidate.allowed_relations, submitted: relation}}
    end
  end

  defp allowed_relation(_candidate, _relation),
    do: {:error, {:admission_rejected, :relation_not_allowed}}

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp validate_reference(value) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= 1_024 do
      :ok
    else
      {:error, {:admission_rejected, :decision_ref}}
    end
  end

  defp commit_options(options) when is_list(options) do
    if Keyword.keyword?(options) and Keyword.keys(options) -- [:lease_ref] == [] do
      lease_ref = Keyword.get(options, :lease_ref)

      if valid_optional_reference?(lease_ref),
        do: {:ok, lease_ref},
        else: {:error, {:admission_rejected, :lease_ref}}
    else
      {:error, {:admission_rejected, :options}}
    end
  end

  defp commit_options(_options), do: {:error, {:admission_rejected, :options}}

  defp valid_optional_reference?(nil), do: true

  defp valid_optional_reference?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= 1_024
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp utc_datetime?(%DateTime{} = value) do
    value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0
  end

  defp utc_datetime?(_value), do: false
end
