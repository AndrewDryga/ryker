defmodule Ryker.Admission do
  @moduledoc """
  Builds and validates one source-neutral admission decision.

  It uses conversation, thread, episode state, and age to bound the choices the
  model may make. It never searches for provider names or status phrases.

  Routing a message is announced on the message's own topics after each
  commit (`Ryker.Ingress.Inbox`): every phase its attempt reaches, and the
  decision.
  """
  alias Ryker.Admission.Attempts
  alias Ryker.Admission.{Candidate, CandidateSearch, Context, ConversationContext}
  alias Ryker.Admission.{ConversationSummaries, CorrelationScope, Decision, Occurrences, Prompt}
  alias Ryker.Admission.Ranking
  alias Ryker.Behaviors
  alias Ryker.Crypto
  alias Ryker.Delivery
  alias Ryker.Episodes
  alias Ryker.Feedback
  alias Ryker.Ingress
  alias Ryker.Knowledge
  alias Ryker.Learning
  alias Ryker.LocalRouting
  alias Ryker.People
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Text
  alias Ryker.UTCDateTime
  alias Ryker.Work
  require Logger

  @active_states [:working, :waiting_for_input, :waiting_for_event]

  @doc """
  Builds the routing context of pending message `input_ref` under the lease
  the caller holds: the message, its conversation, the candidate episodes it
  may continue and their history, bounded by `options` (`:now`, `:lease_ref`,
  the continuation and history windows, `:candidate_limit`). Returns
  `{:ok, context}`, or `{:error, reason}` for a message no longer pending, a
  lease lost, or options it refuses.
  """
  @spec context(String.t(), keyword()) :: {:ok, Context.t()} | {:error, term()}
  def context(input_ref, options) do
    with {:ok, settings} <- validate_options(options),
         {:ok, entry} <- Ingress.Inbox.fetch(input_ref),
         :ok <- pending(entry),
         :ok <- lease_owned(entry, settings.lease_ref),
         {:ok, input} <- input_from_entry(entry) do
      snapshot_context(input, entry, settings)
    end
  end

  @doc """
  Internal — the routing context frozen with a pending entry's attempt, read
  back under `lease_ref` instead of built again: `{:ok, context}`, or
  `{:error, reason}`. `Ryker.Admission.Executor` resumes an attempt with it.
  """
  @spec restore_context(Ingress.Inbox.Entry.t(), String.t()) ::
          {:ok, Context.t()} | {:error, term()}
  def restore_context(%Ingress.Inbox.Entry{} = entry, lease_ref) do
    with :ok <- pending(entry),
         :ok <- lease_owned(entry, lease_ref) do
      restored_context(entry)
    end
  end

  def restore_context(_entry, _lease_ref),
    do: {:error, {:invalid_admission_context_snapshot, :entry}}

  @doc """
  The context a decided message was routed in, restored from its frozen
  snapshot the way a resumed routing run restores it, so another answer to
  the same prompt can be put through the same checks (`validate/2`) without
  routing it: `Ryker.LocalRouting` asks this of every comparison.
  """
  @spec decided_context(Ingress.Inbox.Entry.t()) :: {:ok, Context.t()} | {:error, term()}
  def decided_context(%Ingress.Inbox.Entry{status: :decided} = entry), do: restored_context(entry)

  def decided_context(_entry), do: {:error, {:invalid_admission_context_snapshot, :entry}}

  defp restored_context(entry) do
    with {:ok, input} <- input_from_entry(entry),
         snapshot when is_map(snapshot) <- entry.admission_context,
         {:ok, episode_ids} <- Context.episode_ids(snapshot),
         episodes <- episodes_by_id(episode_ids),
         {:ok, context} <- Context.restore(snapshot, input, entry, episodes) do
      {:ok, context}
    else
      nil -> {:error, {:invalid_admission_context_snapshot, :missing}}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, {:invalid_admission_context_snapshot, :document}}
    end
  end

  defp snapshot_context(input, entry, settings) do
    nested? = Repo.in_transaction?()

    # The local backdrop is captured before the snapshot transaction opens.
    # Its cutoff is this input's own occurrence, so nothing that arrives later
    # can enter it, and a bounded authorized provider read never runs while a
    # database snapshot and its connection are held open.
    captured = capture_conversation_context(entry, settings)
    # The message's meaning is asked for here too, from the embedding server,
    # never while the snapshot holds its connection.
    settings = Map.put(settings, :meaning, meaning(input, settings))

    Repo.transaction(fn ->
      case ensure_snapshot_isolation(nested?) do
        :ok -> build_context_locked(input, entry, settings, captured)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] in [:serialization_failure, :deadlock_detected],
        do: {:error, {:admission_rejected, :context_stale}},
        else: reraise(error, __STACKTRACE__)
  end

  # What the sender said about themselves, where it may be used, or nil.
  defp person_asking(input, entry) do
    case People.about(Ingress.Input.actor_ref(input), entry.destination_conversation_ref) do
      [] -> nil
      facts -> facts
    end
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

  defp build_context_locked(input, entry, settings, captured) do
    with :ok <- lock_conversation(input),
         {:ok, candidates, routing_receipt} <- candidates(input, entry, settings) do
      %Context{
        active_episode_fingerprint:
          active_episode_fingerprint_for_destination(
            input.destination,
            entry.execution_mode
          ),
        built_at: settings.now,
        candidates: candidates,
        candidate_messages:
          candidates |> Enum.flat_map(&Candidate.previewed_messages/1) |> Enum.uniq(),
        continuation_window: settings.continuation_window,
        conversation_context: captured.bundle,
        context_manifest: captured.manifest,
        conversation_episode_count: conversation_episode_count(input, entry.execution_mode),
        input: input,
        input_entry: entry,
        custom_instructions: Ryker.Instructions.snapshot(input.destination),
        person_asking: person_asking(input, entry),
        previous_answer: previous_answer(input, captured),
        repository_choices: repository_choices(entry),
        routing_receipt: routing_receipt,
        slack_addressing: slack_addressing(entry),
        observations: Learning.Observations.context(entry, entry.repository_ref, "", 5),
        knowledge:
          Knowledge.context(
            entry,
            entry.repository_ref,
            {:related, Ingress.RecallText.from(input.content)},
            8
          )
      }
      |> Learning.LearningSources.freeze()
      |> Prompt.fit()
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The repositories a new episode chooses among: those of the frozen
  # profile's environment when it has more than one, each with what the
  # operator wrote about it so the model can tell which the event concerns.
  # Frozen with the context, the list is what the receipt shows even after
  # the environment changes.
  defp repository_choices(%Ingress.Inbox.Entry{work_profile: %{} = document}) do
    with {:ok, profile} <- Ingress.WorkProfile.restore(document),
         [_one, _another | _rest] = refs <- Ingress.WorkProfile.repository_choices(profile) do
      described =
        refs
        |> Settings.Repository.Query.by_refs()
        |> Settings.Repository.Query.select_descriptions()
        |> Repo.all()
        |> Map.new(fn {ref, description, display_name} -> {ref, description || display_name} end)

      Enum.map(refs, &described_choice(&1, described))
    else
      _no_choice -> []
    end
  end

  defp repository_choices(_entry), do: []

  defp described_choice(ref, described) do
    case Map.get(described, ref) do
      nil -> %{"ref" => ref}
      description -> %{"ref" => ref, "description" => description}
    end
  end

  # Routing is asked how a person feels about Ryker's previous answer only
  # when a person writes a new message in Slack or Chat after one: an app, an
  # alert or an edit says nothing about how an answer landed.
  defp previous_answer(
         %Ingress.Input{actor: %{kind: :user}, event_kind: :message, source: %{kind: kind}},
         captured
       )
       when kind in ["slack", "control_plane"],
       do: captured.previous_answer

  defp previous_answer(_input, _captured), do: nil

  defp capture_conversation_context(entry, settings) do
    entry
    |> ConversationContext.capture(
      local_history_limit: settings.local_history_limit,
      reader: settings.source_reader
    )
    |> ConversationContext.with_thread_summary(ConversationSummaries.thread(entry, settings.now))
  end

  defp slack_addressing(%Ingress.Inbox.Entry{slack_audience: nil, slack_bot_user_ref: nil}),
    do: nil

  defp slack_addressing(%Ingress.Inbox.Entry{} = entry) do
    %{
      "audience" => Atom.to_string(entry.slack_audience),
      "ryker_user_ref" => entry.slack_bot_user_ref
    }
  end

  @doc """
  Checks a routing decision against its context: the action and reactions the
  message allows, the episode it names among the candidates, the relation,
  repository and source owner. Returns `{:ok, %{candidate, decision,
  execution_mode}}`, or `{:error, {:admission_rejected, reason}}`.
  """
  @spec validate(Context.t(), Decision.t()) ::
          {:ok,
           %{
             candidate: Candidate.t() | nil,
             decision: Decision.t(),
             execution_mode: :live | :shadow
           }}
          | {:error, term()}
  def validate(%Context{} = context, %Decision{} = decision) do
    with {:ok, decision} <- Decision.prepare(decision),
         :ok <- allowed_action(context.input, decision.action),
         :ok <- allowed_reactions(context.input, decision),
         {:ok, candidate} <- selected_candidate(context, decision.episode_ref),
         :ok <- allowed_relation(candidate, decision.relation),
         :ok <- allowed_repository(context, decision),
         :ok <- allowed_repository_source(context, decision),
         :ok <- source_owner_selection(context, candidate, decision) do
      {:ok,
       %{
         candidate: candidate,
         decision: decision,
         execution_mode: context.input_entry.execution_mode
       }}
    end
  end

  def validate(_context, _decision), do: {:error, {:admission_rejected, :context}}

  @doc """
  A short code for why routing's checks refused an answer, kept with each
  refused answer (`Ryker.Admission.Attempts.reject/3`) and with the local
  routing model's (`Ryker.LocalRouting.Verdict`): `not_json` for text that is
  not one JSON object, `decision:<field>` for a field that breaks the
  decision contract, and `rejected:<why>` for a decision the frozen context
  does not allow, such as `rejected:unknown_candidate` for earlier work that
  was not offered.
  """
  @spec refusal(term()) :: String.t()
  def refusal({:invalid_candidate, :json_object}), do: "not_json"
  def refusal({:invalid_decision, field}) when is_atom(field), do: "decision:#{field}"
  def refusal({:admission_rejected, why}) when is_atom(why), do: "rejected:#{why}"
  def refusal({:admission_rejected, why, _details}) when is_atom(why), do: "rejected:#{why}"
  def refusal(_other), do: "rejected"

  # The repositories offered are route authority: a new episode on a route
  # with several names one of them, and no other route may name any. The
  # parser already keeps every other action from naming one.
  defp allowed_repository(%Context{repository_choices: []}, %Decision{repository: nil}), do: :ok

  defp allowed_repository(%Context{repository_choices: []}, _decision),
    do: {:error, {:admission_rejected, :repository_not_available}}

  defp allowed_repository(_context, %Decision{action: action, repository: nil})
       when action != :start_episode,
       do: :ok

  defp allowed_repository(%Context{repository_choices: choices}, %Decision{repository: nil}),
    do: {:error, {:admission_rejected, :repository_required, allowed: choice_refs(choices)}}

  defp allowed_repository(%Context{repository_choices: choices}, %Decision{repository: chosen}) do
    allowed = choice_refs(choices)

    if chosen in allowed,
      do: :ok,
      else:
        {:error,
         {:admission_rejected, :repository_not_allowed, allowed: allowed, submitted: chosen}}
  end

  defp choice_refs(choices), do: Enum.map(choices, & &1["ref"])

  # Only a route whose repository the host already selected can carry a source.
  defp allowed_repository_source(_context, %Decision{repository_source: nil}), do: :ok

  defp allowed_repository_source(%Context{input_entry: %{repository_ref: repository_ref}}, _dec)
       when is_binary(repository_ref),
       do: :ok

  defp allowed_repository_source(_context, _decision),
    do: {:error, {:admission_rejected, :repository_source_not_available}}

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
          entry: Ingress.Inbox.Entry.t(),
          episode: Episodes.Episode.t() | nil,
          status: :applied | :duplicate | :superseded,
          transitions: [Ryker.Episodes.Transition.t()]
        }

  @doc "`commit/4` with no options."
  @spec commit(Context.t(), Decision.t(), String.t()) ::
          {:ok, commit_result()} | {:error, term()}
  def commit(%Context{} = context, %Decision{} = decision, decision_ref),
    do: commit(context, decision, decision_ref, [])

  @doc """
  Applies a validated decision in one transaction: the episode transitions it
  makes and the decision recorded on the message's entry. `options` take the
  `:lease_ref` the attempt holds and the `:work_policy` new work runs under.
  Returns `{:ok, %{status: :applied | :duplicate | :superseded, entry,
  episode, transitions}}` (`t:commit_result/0`), or `{:error, reason}`, such
  as `{:admission_rejected, :context_stale}` when the episode moved meanwhile.
  """
  @spec commit(Context.t(), Decision.t(), String.t(), keyword()) ::
          {:ok, commit_result()} | {:error, term()}
  def commit(%Context{} = context, %Decision{} = decision, decision_ref, options) do
    with {:ok, settings} <- commit_options(options),
         {:ok, decision} <- Decision.prepare(decision),
         :ok <- validate_reference(decision_ref) do
      Repo.transaction(fn ->
        commit_in_transaction(context, decision, decision_ref, settings)
      end)
    end
  end

  def commit(_context, _decision, _decision_ref, _options),
    do: {:error, {:admission_rejected, :context}}

  defp commit_in_transaction(context, decision, decision_ref, settings) do
    with {:ok, entry} <- load_entry(context.input_entry.id),
         {:ok, result} <-
           commit_locked(
             entry,
             context,
             decision,
             decision_ref,
             settings.lease_ref,
             settings.work_policy
           ) do
      result
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # Whether a message follows up on finished work is a question about when the
  # person sent it, not when routing got to it: a delayed or retried routing
  # must not turn a quick follow-up into background-only work. A clock ahead
  # of the host's never places the message in the future.
  defp arrival(%DateTime{} = occurred_at, now) do
    if DateTime.compare(occurred_at, now) == :lt, do: occurred_at, else: now
  end

  defp arrival(_occurred_at, now), do: now

  defp validate_options(options) when is_list(options) do
    now = Keyword.get(options, :now)
    continuation_window = Keyword.get(options, :continuation_window)
    history_window = Keyword.get(options, :history_window)
    candidate_limit = Keyword.get(options, :candidate_limit, 20)
    lease_ref = Keyword.get(options, :lease_ref)
    local_history_limit = Keyword.get(options, :local_history_limit, 20)
    source_reader = Keyword.get(options, :source_reader)
    embedder = Keyword.get_lazy(options, :embedder, &default_embedder/0)

    with :ok <- context_option_keys(options),
         :ok <- context_value(UTCDateTime.utc?(now), :now),
         :ok <- context_value(positive_integer?(continuation_window), :continuation_window),
         :ok <- valid_history_window(history_window, continuation_window),
         :ok <- valid_candidate_limit(candidate_limit),
         :ok <- valid_local_history_limit(local_history_limit),
         :ok <- context_value(valid_source_reader?(source_reader), :source_reader),
         :ok <- context_value(is_nil(embedder) or is_function(embedder, 2), :embedder),
         :ok <- context_value(valid_optional_reference?(lease_ref), :lease_ref) do
      {:ok,
       %{
         candidate_limit: candidate_limit,
         continuation_window: continuation_window,
         history_window: history_window,
         lease_ref: lease_ref,
         local_history_limit: local_history_limit,
         now: now,
         source_reader: source_reader,
         embedder: embedder
       }}
    end
  end

  defp validate_options(_options), do: {:error, {:invalid_admission_context, :options}}

  # Search by meaning runs while RYKER_EMBEDDINGS_URL names a server
  # (`Ryker.Embeddings`); tests pass their own embedder or none.
  defp default_embedder do
    if Ryker.Embeddings.url(), do: &Ryker.Embeddings.embed/2
  end

  # The message's vector for the search by meaning, or why there is none. A
  # slow or stopped server costs routing at most three seconds, and the
  # search goes on by words and identifiers.
  defp meaning(_input, %{embedder: nil}), do: nil

  defp meaning(input, %{embedder: embed}) do
    case Ingress.RecallText.from(input.content) do
      "" ->
        nil

      text ->
        case embed.([text], timeout_ms: 3_000) do
          {:ok, [vector]} -> %{vector: vector, model: Ryker.Embeddings.model()}
          {:error, reason} -> %{unavailable: unavailable(reason)}
        end
    end
  end

  defp unavailable(:timeout), do: "the embedding server did not answer in time"
  defp unavailable(:unreachable), do: "the embedding server could not be reached"
  defp unavailable({:status, status}), do: "the embedding server answered #{status}"
  defp unavailable(_reason), do: "the embedding server's answer could not be read"

  defp valid_local_history_limit(value) do
    context_value(is_integer(value) and value >= 10 and value <= 20, :local_history_limit)
  end

  defp valid_source_reader?(nil), do: true
  defp valid_source_reader?({module, _client}) when is_atom(module), do: true
  defp valid_source_reader?(_reader), do: false

  defp context_option_keys(options) do
    allowed = [
      :candidate_limit,
      :continuation_window,
      :embedder,
      :history_window,
      :lease_ref,
      :local_history_limit,
      :now,
      :source_reader
    ]

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

  defp lease_owned(%Ingress.Inbox.Entry{lease_ref: nil}, nil), do: :ok

  defp lease_owned(%Ingress.Inbox.Entry{lease_ref: lease_ref}, lease_ref)
       when is_binary(lease_ref), do: :ok

  defp lease_owned(_entry, _lease_ref), do: {:error, {:admission_rejected, :lease_lost}}

  defp input_from_entry(entry) do
    Ingress.Input.new(%{
      actor: %{kind: entry.actor_kind, ref: entry.actor_ref},
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
      source_capabilities: entry.source_capabilities,
      source_item_ref: entry.source_item_ref
    })
  end

  defp load_entry(id) do
    entry =
      id
      |> Ingress.Inbox.Entry.Query.by_id()
      |> Ingress.Inbox.Entry.Query.lock_for_update()
      |> Repo.fetch()

    case entry do
      {:ok, entry} -> {:ok, entry}
      {:error, :not_found} -> {:error, {:admission_rejected, :input_not_found}}
    end
  end

  defp episodes_by_id([]), do: %{}

  defp episodes_by_id(ids) do
    ids
    |> Episodes.Episode.Query.by_ids()
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp commit_locked(
         %Ingress.Inbox.Entry{status: status} = entry,
         _context,
         decision,
         decision_ref,
         _lease_ref,
         _work_policy
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
        input_ref: Ingress.Inbox.ref(entry),
        stored_decision_ref: entry.decision_ref,
        submitted_decision_ref: decision_ref,
        stored_fingerprint: entry.decision_fingerprint,
        submitted_fingerprint: submitted}}
    end
  end

  defp commit_locked(
         %Ingress.Inbox.Entry{
           status: :blocked,
           last_error_code: error_code,
           last_error_detail: error_detail
         },
         _context,
         _decision,
         _decision_ref,
         _lease_ref,
         _work_policy
       ),
       do: {:error, {:input_blocked, error_code, error_detail}}

  defp commit_locked(
         %Ingress.Inbox.Entry{status: :pending} = entry,
         context,
         decision,
         decision_ref,
         lease_ref,
         work_policy
       ) do
    with :ok <- same_input(entry, context),
         :ok <- lease_owned(entry, lease_ref),
         {:ok, selection} <- validate(context, decision),
         {:ok, selection, source_owner} <- current_routing_scope(context, selection) do
      apply_and_persist(
        context,
        entry,
        selection,
        decision,
        decision_ref,
        source_owner,
        work_policy
      )
    end
  end

  defp apply_and_persist(
         context,
         entry,
         _selection,
         decision,
         decision_ref,
         {:ok, {episode, latest}},
         _work_policy
       )
       when latest >= context.input.revision do
    details = [
      native_input_id: context.input.native_input_id,
      submitted: context.input.revision,
      latest: latest
    ]

    persist_superseded(entry, decision, decision_ref, episode, details)
  end

  defp apply_and_persist(
         context,
         entry,
         selection,
         decision,
         decision_ref,
         {:ok, {%Episodes.Episode{} = owner_episode, _earlier_revision}},
         work_policy
       ) do
    if source_owner_matches_selection?(owner_episode, selection) do
      apply_and_persist_current(context, entry, selection, decision, decision_ref, work_policy)
    else
      {:error, {:admission_rejected, :context_stale}}
    end
  end

  defp apply_and_persist(
         context,
         entry,
         selection,
         decision,
         decision_ref,
         {:error, :not_found},
         work_policy
       ) do
    apply_and_persist_current(context, entry, selection, decision, decision_ref, work_policy)
  end

  defp source_owner_matches_selection?(owner, selection) do
    case selection.decision.action do
      action when action in [:start_episode, :continue_episode, :reply] ->
        source_owner_routing_matches?(owner, selection)

      _non_routing_action ->
        true
    end
  end

  defp source_owner_routing_matches?(%Episodes.Episode{state: :cancelled, id: id}, selection) do
    match?(%Candidate{episode: %Episodes.Episode{id: ^id}}, selection.candidate) and
      selection.decision.relation == :history_only
  end

  defp source_owner_routing_matches?(%Episodes.Episode{id: id}, selection) do
    match?(%Episodes.Episode{id: ^id}, existing_episode(selection))
  end

  defp apply_and_persist_current(
         context,
         entry,
         selection,
         decision,
         decision_ref,
         work_policy
       ) do
    case apply_episode(context, entry, selection) do
      {:ok, transitions, episode} ->
        sources = Learning.LearningSources.authorize_context(context, entry)

        if is_list(context.source_dependencies) and not is_list(sources),
          do: Repo.rollback({:admission_rejected, :context_stale})

        with :ok <-
               Learning.Observations.reauthorize(
                 entry,
                 entry.repository_ref,
                 context.observations
               ),
             :ok <-
               Knowledge.still_current(
                 entry,
                 entry.repository_ref,
                 context.knowledge
               ),
             :ok <- claim_occurrences(context, episode),
             :ok <- maybe_pin_episode(episode, work_policy, decision),
             {:ok, episode} <-
               maybe_resume_blocked_episode(episode, admitted_input_ref(transitions)),
             {:ok, decided} <- persist_decision(entry, decision, decision_ref, episode),
             :ok <- keep_sentiment(context, decision, decided),
             :ok <- Learning.Observations.record_excerpt_in_transaction(decided),
             :ok <-
               finalize_assignment_runs(entry, decision, decision_ref, episode, :decided) do
          {:ok, %{entry: decided, episode: episode, status: :applied, transitions: transitions}}
        end

      {:error, {:stale_input_revision, details} = reason} ->
        supersede_stale_revision(entry, selection, decision, decision_ref, details, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # How the sender feels about Ryker's previous answer is feedback on that
  # answer's request, kept with the decision that read it. It is an input,
  # never a dependency: one the host cannot keep is logged, and the decision
  # commits exactly as it would have without it.
  defp keep_sentiment(
         %Context{previous_answer: %{"request" => request}, input: input},
         %Decision{sentiment: %{feeling: feeling, reason: reason}},
         decided
       ) do
    case Feedback.record_in_transaction(%{
           kind: :sentiment,
           value: Atom.to_string(feeling),
           note: reason,
           actor_ref: input.actor.ref,
           source: input.source.kind,
           source_ref: Ingress.Inbox.ref(decided),
           occurred_at: input.occurred_at,
           request: feedback_request(request)
         }) do
      {:ok, _recorded} ->
        :ok

      {:error, error} ->
        Logger.warning("routing sentiment not kept: #{inspect(error, limit: 5)}")
        :ok
    end
  end

  defp keep_sentiment(_context, _decision, _decided), do: :ok

  defp feedback_request(%{"episode_id" => id}), do: {:episode, id}
  defp feedback_request(%{"input_id" => id}), do: {:input, id}

  defp supersede_stale_revision(entry, selection, decision, decision_ref, details, reason) do
    case existing_episode(selection) do
      %Episodes.Episode{} = episode ->
        persist_superseded(entry, decision, decision_ref, episode, details)

      nil ->
        {:error, reason}
    end
  end

  defp persist_superseded(entry, decision, decision_ref, episode, details) do
    with {:ok, decided} <-
           persist_superseded_decision(entry, decision, decision_ref, episode, details),
         :ok <- finalize_assignment_runs(entry, decision, decision_ref, episode, :superseded) do
      {:ok, %{entry: decided, episode: episode, status: :superseded, transitions: []}}
    end
  end

  defp finalize_assignment_runs(entry, decision, decision_ref, episode, outcome) do
    selected_episode =
      if decision.action in [:start_episode, :continue_episode, :reply], do: episode

    Behaviors.StandingRules.finalize_assignment_runs_in_transaction(
      Ingress.Inbox.ref(entry),
      decision.action,
      decision_ref,
      selected_episode,
      outcome
    )
  end

  @doc "The episode whose work owns this input's source message now."
  @spec fetch_source_owner(Context.t()) :: {:ok, Episodes.Episode.t()} | {:error, :not_found}
  def fetch_source_owner(%Context{} = context) do
    with {:ok, {episode, _revision}} <- fetch_current_source_owner(context), do: {:ok, episode}
  end

  # An edit or delete follows its source item's effective owner even when that
  # episode now lives in another conversation, so a revision can never be
  # reassigned by rank or split across two episodes.
  defp fetch_current_source_owner(context) do
    Episodes.Origins.fetch_current_owner(
      context.input.native_input_id,
      context.input.destination.transport,
      context.input_entry.execution_mode
    )
  end

  defp current_routing_scope(%Context{} = context, selection) do
    with :ok <- lock_conversation(context.input),
         :ok <- compare_routing_generation(context, selection) do
      source_owner =
        if context.input_entry.execution_mode == :shadow,
          do: {:error, :not_found},
          else: fetch_current_source_owner(context)

      {:ok, refresh_selection(selection), source_owner}
    end
  end

  defp compare_routing_generation(context, selection) do
    if routes_episode?(selection) and creates_episode?(selection),
      do: compare_conversation_generation(context),
      else: :ok
  end

  defp compare_conversation_generation(context) do
    execution_mode = context.input_entry.execution_mode

    same_count? =
      conversation_episode_count(context.input, execution_mode) ==
        context.conversation_episode_count

    same_active? =
      active_episode_fingerprint_for_destination(context.input.destination, execution_mode) ==
        context.active_episode_fingerprint

    if same_count? and same_active?,
      do: :ok,
      else: {:error, {:admission_rejected, :context_stale}}
  end

  defp refresh_selection(%{candidate: nil} = selection), do: selection

  defp refresh_selection(%{candidate: candidate} = selection) do
    current = Repo.peek(Episodes.Episode.Query.by_id(candidate.episode.id))

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
    Episodes.ConversationLock.lock(input.destination)
  end

  defp same_input(entry, context) do
    expected = context.input_entry

    cond do
      entry.id != expected.id ->
        {:error, {:admission_rejected, :input_changed}}

      entry.event_fingerprint != expected.event_fingerprint ->
        {:error, {:admission_rejected, :input_changed}}

      Ingress.Input.fingerprint(context.input) != entry.event_fingerprint ->
        {:error, {:admission_rejected, :input_changed}}

      true ->
        :ok
    end
  end

  defp apply_episode(_context, _entry, %{decision: %{action: action}})
       when action in [:ignore, :react, :quick_reply],
       do: {:ok, [], nil}

  defp apply_episode(context, entry, selection) do
    admit = admit_command(context, entry, selection)
    existing = existing_episode(selection)

    with {:ok, [admitted]} <- apply_admit(admit, existing),
         {:ok, met} <- answer_met_watches(existing, admitted.episode, context.input),
         {:ok, resumed} <- maybe_resume_wait(context, selection, admit, admitted.episode, met) do
      transitions = [admitted | resumed]
      {:ok, transitions, transitions |> List.last() |> Map.fetch!(:episode)}
    end
  end

  defp apply_admit(admit, %Episodes.Episode{}), do: Episodes.apply_batch_in_transaction([admit])

  defp apply_admit(admit, nil), do: Episodes.apply_batch_in_transaction([admit])

  # A watch riding beside the wait an episode holds hears its event here; the
  # wait itself is resumed by `maybe_resume_wait/5`.
  defp answer_met_watches(nil, _episode, _input), do: {:ok, []}

  defp answer_met_watches(%Episodes.Episode{}, episode, input),
    do: Records.answer_met_watches_in_transaction(episode, input)

  defp admit_command(context, entry, selection) do
    existing = existing_episode(selection)
    input = context.input
    turn_ref = "ingress-turn:#{entry.id}"

    %Episodes.Command.AdmitInput{
      actor_ref: Ingress.Input.actor_ref(input),
      destination: target_destination(input, existing),
      episode_id: if(existing, do: existing.id, else: entry.id),
      episode_key: if(existing, do: existing.key, else: "ingress-input:#{entry.id}"),
      execution_mode: entry.execution_mode,
      linked_episode_id: linked_episode(selection, existing),
      native_input_id: routed_native_input_id(input, entry),
      occurred_at: input.occurred_at,
      payload: Ingress.Input.document(input),
      revision: input.revision,
      turn_ref: turn_ref
    }
  end

  defp maybe_resume_wait(context, selection, admit, current, met) do
    existing = existing_episode(selection)

    cond do
      is_nil(existing) or not waiting?(current) or
          not input_after_wait?(current, context.input.occurred_at) ->
        {:ok, []}

      Records.user_resumable_wait?(current.owner_ref, context.input) ->
        with :ok <- Records.InputRequests.associate_in_transaction(current, context.input_entry),
             {:ok, transitions} <- resume_wait(context, admit, current),
             :ok <-
               Records.resolve_wait_in_transaction(current.owner_ref, context.input.event_kind) do
          {:ok, transitions}
        end

      # A watch beside the watch the task waits on heard its event: the task
      # wakes as it would for its own, and the wait it held stays open for its
      # next turn. Several watches may wait together (`Ryker.Work.Validator`).
      met != [] and Records.open_event_wait?(current.id, current.owner_ref) ->
        resume_wait(context, admit, current)

      true ->
        {:ok, []}
    end
  end

  defp resume_wait(context, admit, current) do
    Episodes.apply_batch_in_transaction([
      %Episodes.Command.ResumeWait{
        episode_key: current.key,
        expected_wait: %{kind: current.owner_kind, ref: current.owner_ref},
        occurred_at: context.input.occurred_at,
        resolution_ref: Episodes.Command.dedupe_key(admit),
        turn_ref: admit.turn_ref
      }
    ])
  end

  defp existing_episode(%{
         candidate: %Candidate{} = candidate,
         decision: decision,
         execution_mode: execution_mode
       }) do
    if decision.relation == :same_work and candidate.episode.execution_mode == execution_mode,
      do: candidate.episode,
      else: nil
  end

  defp existing_episode(_selection), do: nil

  defp target_destination(_input, %Episodes.Episode{} = episode) do
    %{
      conversation_ref: episode.destination_conversation_ref,
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    }
  end

  defp target_destination(input, nil), do: input.destination

  defp linked_episode(_selection, %Episodes.Episode{} = episode), do: episode.linked_episode_id

  defp linked_episode(%{candidate: %Candidate{} = candidate, decision: decision}, nil) do
    if decision.relation == :history_only or decision.relation == :same_work,
      do: candidate.episode.id,
      else: nil
  end

  defp linked_episode(_selection, nil), do: nil

  defp routed_native_input_id(input, %{execution_mode: :shadow, id: entry_id}),
    do: "shadow:#{input.native_input_id}:#{entry_id}"

  defp routed_native_input_id(input, _entry), do: input.native_input_id

  defp waiting?(%Episodes.Episode{state: state})
       when state in [:waiting_for_input, :waiting_for_event],
       do: true

  defp waiting?(_episode), do: false

  defp input_after_wait?(%Episodes.Episode{} = episode, occurred_at) do
    wait_mark =
      episode.id
      |> Episodes.Event.Query.by_episode_id()
      |> Episodes.Event.Query.wait_marks(episode.owner_ref)
      |> Episodes.Event.Query.ordered_by_sequence_desc()
      |> Episodes.Event.Query.limit_to(1)
      |> Repo.fetch()

    case wait_mark do
      {:error, :not_found} -> false
      {:ok, event} -> DateTime.compare(occurred_at, event.occurred_at) == :gt
    end
  end

  defp persist_decision(entry, decision, decision_ref, episode) do
    entry
    |> Ingress.Inbox.Entry.Changeset.decide(decision, decision_ref, episode && episode.id)
    |> Repo.update()
    |> case do
      {:ok, decided} ->
        Ingress.Inbox.broadcast_input_updated(decided)

        with :ok <- Attempts.committed(decided),
             :ok <- LocalRouting.queue_in_transaction(decided),
             {:ok, _response} <- maybe_enqueue_routing_response(decided) do
          {:ok, decided}
        end

      {:error, changeset} ->
        {:error, {:persistence_failed, :admission_decision, changeset.errors}}
    end
  end

  defp maybe_enqueue_routing_response(%Ingress.Inbox.Entry{execution_mode: :shadow}),
    do: {:ok, nil}

  defp maybe_enqueue_routing_response(%Ingress.Inbox.Entry{} = entry),
    do: Delivery.RoutingResponseCustody.enqueue_in_transaction(entry)

  defp persist_superseded_decision(entry, decision, decision_ref, episode, details) do
    entry
    |> Ingress.Inbox.Entry.Changeset.supersede(decision, decision_ref, episode.id, details)
    |> Repo.update()
    |> case do
      {:ok, decided} ->
        :ok =
          Ingress.Inbox.record_transition_in_transaction(decided, :superseded,
            detail: decided.last_error_detail
          )

        Ingress.Inbox.broadcast_input_updated(decided)
        {:ok, decided}

      {:error, changeset} ->
        {:error, {:persistence_failed, :admission_decision, changeset.errors}}
    end
  end

  # One trusted occurrence has at most one active owning episode. Two channels
  # reporting the same authenticated object therefore cannot both create active
  # work: the loser sees the winner's claim and classifies again against it.
  defp claim_occurrences(_context, nil), do: :ok

  defp claim_occurrences(%Context{} = context, %Episodes.Episode{} = episode) do
    scope_ref = Occurrences.scope_ref(context.input)
    input_ref = Ingress.Inbox.ref(context.input_entry)

    context.input
    |> Occurrences.for_input()
    |> Enum.reduce_while(:ok, fn occurrence, :ok ->
      attributes = %{
        episode_id: episode.id,
        input_ref: input_ref,
        scope_ref: scope_ref,
        namespace: occurrence.namespace,
        occurrence_ref: occurrence.occurrence_ref,
        lifecycle_state: occurrence.lifecycle_state,
        established_at: context.input.occurred_at
      }

      attributes |> Episodes.CorrelationClaims.claim_in_transaction() |> claimed(episode)
    end)
  end

  defp claimed({:ok, _claim}, _episode), do: {:cont, :ok}

  defp claimed({:error, {:occurrence_claimed, owner}}, %Episodes.Episode{id: id})
       when owner.episode_id == id,
       do: {:cont, :ok}

  defp claimed({:error, {:occurrence_claimed, owner}}, _episode) do
    {:halt,
     {:error, {:admission_rejected, :occurrence_claimed, owner_episode_id: owner.episode_id}}}
  end

  defp maybe_pin_episode(nil, _work_policy, _decision), do: :ok
  defp maybe_pin_episode(_episode, nil, _decision), do: :ok

  defp maybe_pin_episode(
         %Episodes.Episode{id: episode_id},
         %{digest: policy_digest, name: policy} = work_policy,
         %Decision{} = decision
       ) do
    case Work.Custody.pin_episode_in_transaction(episode_id, policy, policy_digest,
           authority_digest: Map.get(work_policy, :authority_digest),
           environment_ref: Map.get(work_policy, :environment_ref),
           repository_context: Map.get(work_policy, :repository_context),
           repository_ref: Map.get(work_policy, :repository_ref),
           repository_source: decision.repository_source
         ) do
      {:ok, _session} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp admitted_input_ref([%{event: %{kind: :input_admitted, dedupe_key: input_ref}} | _]),
    do: input_ref

  defp admitted_input_ref(_transitions), do: nil

  defp maybe_resume_blocked_episode(nil, _input_ref), do: {:ok, nil}

  defp maybe_resume_blocked_episode(%Episodes.Episode{} = episode, input_ref),
    do: Work.Custody.resume_blocked_in_transaction(episode, input_ref)

  defp load_decided_episode(nil), do: nil
  defp load_decided_episode(id), do: Repo.peek(Episodes.Episode.Query.by_id(id))

  # Retrieval is bounded, indexed and explainable: five lanes fill a pool of at
  # most 200 eligible episodes, the exact source item's owner is resolved
  # separately so no lane cap can hide it, and ranking chooses at most twenty
  # options while reserving places for supported matches outside this thread.
  defp candidates(input, entry, settings) do
    scope = CorrelationScope.for_input(input)

    %{selected: selected, receipt: receipt} =
      CandidateSearch.search(%{
        scope: scope,
        transport: input.destination.transport,
        thread_ref: input.destination.thread_ref,
        text: Ingress.RecallText.from(input.content),
        identifiers: Episodes.RoutingDigests.input_identifiers(input.content),
        native_input_id: input.native_input_id,
        execution_mode: entry.execution_mode,
        repository_ref: entry.repository_ref,
        occurrences: Occurrences.for_input(input),
        meaning: settings[:meaning],
        candidate_limit: settings.candidate_limit,
        history_cutoff: DateTime.add(settings.now, -settings.history_window, :second),
        now: settings.now
      })

    episode_ids = Enum.map(selected, & &1.episode.id)
    endpoints = input_event_endpoints(episode_ids)
    outcomes = candidate_outcomes(episode_ids)
    arrived = arrival(input.occurred_at, settings.now)

    candidates =
      Enum.map(selected, fn ranked ->
        Candidate.new(%{
          allowed_relations:
            Candidate.allowed_relations(ranked.episode, %{
              continuation_window: settings.continuation_window,
              input_repository: candidate_input_repository(entry),
              now: arrived,
              pinned_repository: ranked.repository_ref,
              source_owner: ranked.source_owner
            }),
          digest: Episodes.RoutingDigests.document(ranked.digest),
          endpoints: Map.get(endpoints, ranked.episode.id, %{}),
          episode: ranked.episode,
          idle_minutes: max(div(DateTime.diff(arrived, ranked.episode.updated_at), 60), 0),
          match: Ranking.document(ranked),
          outcome: Map.get(outcomes, ranked.episode.id),
          same_thread: ranked.features.same_thread,
          source_owner: ranked.source_owner
        })
      end)

    {:ok, candidates, receipt}
  end

  # A Slack entry carries the channel's default repository before the model
  # selects the repository named in the message. That default cannot rule out
  # continuing work already pinned to a different repository in this channel.
  defp candidate_input_repository(%Ingress.Inbox.Entry{source_kind: "slack"}), do: nil

  defp candidate_input_repository(%Ingress.Inbox.Entry{repository_ref: repository_ref}),
    do: repository_ref

  # What each candidate last said or decided: routing chose between earlier
  # work it knew only by its opening message and the state "complete".
  @outcome_characters 240

  defp candidate_outcomes([]), do: %{}

  defp candidate_outcomes(episode_ids) do
    episode_ids
    |> Work.Turn.Query.latest_accepted_outcomes()
    |> Repo.all()
    |> Enum.flat_map(fn {episode_id, delivery, delivered_at, intent} ->
      case outcome(delivery, delivered_at, intent) do
        nil -> []
        outcome -> [{episode_id, outcome}]
      end
    end)
    |> Map.new()
  end

  defp outcome(%{"message" => message}, delivered_at, _intent) when is_binary(message) do
    prefix = if delivered_at, do: "Replied: ", else: "Reply accepted, not yet delivered: "
    prefix <> outcome_text(message)
  end

  defp outcome(_delivery, _delivered_at, %{"result" => %{"decision_reason" => reason}})
       when is_binary(reason),
       do: "No reply: " <> outcome_text(reason)

  defp outcome(_delivery, _delivered_at, _intent), do: nil

  defp outcome_text(text) do
    text
    |> Candidate.model_text()
    |> String.replace(~r/\s+/, " ")
    |> Text.shorten(@outcome_characters)
  end

  defp conversation_episode_count(input, execution_mode) do
    destination = input.destination

    destination.transport
    |> Episodes.Episode.Query.by_conversation(destination.conversation_ref)
    |> Episodes.Episode.Query.by_execution_mode(execution_mode)
    |> Repo.aggregate(:count)
  end

  defp current_active_episode_ids(destination, execution_mode) do
    destination.transport
    |> Episodes.Episode.Query.by_conversation(destination.conversation_ref)
    |> Episodes.Episode.Query.by_execution_mode(execution_mode)
    |> Episodes.Episode.Query.by_states(@active_states)
    |> Episodes.Episode.Query.ordered_by_id()
    |> Episodes.Episode.Query.select_ids()
    |> Repo.all()
  end

  defp active_episode_fingerprint_for_destination(destination, execution_mode) do
    destination
    |> current_active_episode_ids(execution_mode)
    |> Ryker.CanonicalJSON.digest()
  end

  @doc """
  Internal — the first and the latest message event of each episode, by
  episode id (`%{first: event, latest: event}`), read without the history
  between them. Building a context's candidates reads it.
  """
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

  defp endpoint_row(episode_id, position) do
    admissions =
      episode_id
      |> Episodes.Event.Query.by_episode_id()
      |> Episodes.Event.Query.by_kind(:input_admitted)

    ordered =
      if position == :first,
        do: Episodes.Event.Query.ordered_by_occurred_at(admissions),
        else: Episodes.Event.Query.ordered_by_occurred_at_desc(admissions)

    ordered
    |> Episodes.Event.Query.limit_to(1)
    |> Repo.peek()
  end

  defp selected_candidate(_context, nil), do: {:ok, nil}

  defp selected_candidate(%Context{} = context, ref) do
    case Enum.find(context.candidates, &(&1.ref == ref)) do
      nil -> {:error, {:admission_rejected, :unknown_candidate}}
      candidate -> {:ok, candidate}
    end
  end

  defp allowed_action(input, action) do
    if action in Ingress.Input.allowed_actions(input),
      do: :ok,
      else: {:error, {:admission_rejected, :action_not_allowed, submitted: action}}
  end

  # Every emoji routing adds, whether as a reaction or beside a quick reply,
  # must be one the source can take: the adapter's own names when it issues
  # them, any standard name when it does not, and none when it cannot react.
  defp allowed_reactions(_input, %{reactions: nil}), do: :ok

  defp allowed_reactions(input, %{reactions: reactions}) do
    case Ingress.Input.reaction_names(input) do
      :any ->
        :ok

      names when is_list(names) ->
        case Enum.reject(reactions, &(&1 in names)) do
          [] ->
            :ok

          refused ->
            {:error,
             {:admission_rejected, :reaction_not_allowed, allowed: names, submitted: refused}}
        end

      nil ->
        {:error, {:admission_rejected, :reactions_not_available}}
    end
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
    if Keyword.keyword?(options) and Keyword.keys(options) -- [:lease_ref, :work_policy] == [] do
      lease_ref = Keyword.get(options, :lease_ref)
      work_policy = Keyword.get(options, :work_policy)

      cond do
        not valid_optional_reference?(lease_ref) ->
          {:error, {:admission_rejected, :lease_ref}}

        not valid_optional_work_policy?(work_policy) ->
          {:error, {:admission_rejected, :work_policy}}

        true ->
          {:ok, %{lease_ref: lease_ref, work_policy: work_policy}}
      end
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

  defp valid_optional_work_policy?(nil), do: true

  defp valid_optional_work_policy?(%{digest: digest, name: name} = policy) do
    valid_optional_reference?(name) and Crypto.sha256_hex?(digest) and
      valid_optional_reference?(Map.get(policy, :repository_ref))
  end

  defp valid_optional_work_policy?(_policy), do: false

  # -- For the console ---------------------------------------------------------

  @doc "The sentiment in a routing result's `sentiment` value, or nil."
  defdelegate sentiment(value), to: Ryker.Admission.Sentiment, as: :parse
end
