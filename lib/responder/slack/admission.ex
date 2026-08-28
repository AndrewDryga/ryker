defmodule Responder.Slack.Admission do
  @moduledoc """
  Builds and validates one provider-blind Slack admission decision.

  It uses conversation, thread, episode state, and age to bound the choices the
  model may make. It never searches for provider names or status phrases.
  """

  import Ecto.Query

  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode, Event}
  alias Responder.Repo
  alias Responder.Slack.Admission.{Candidate, Context, Decision}
  alias Responder.Slack.{Inbox, Input}
  alias Responder.Slack.Inbox.{Entry, EntryChangeset}

  @active_states [:working, :waiting_for_input, :waiting_for_event]

  @spec context(String.t(), keyword()) :: {:ok, Context.t()} | {:error, term()}
  def context(input_ref, options) do
    with {:ok, settings} <- validate_options(options),
         {:ok, entry} <- Inbox.fetch(input_ref),
         :ok <- pending(entry),
         {:ok, input} <- input_from_entry(entry) do
      snapshot_context(input, entry, settings)
    end
  end

  defp snapshot_context(input, entry, settings) do
    Repo.transaction(fn ->
      case lock_conversation(input) do
        :ok ->
          %Context{
            built_at: settings.now,
            candidates: candidates(input, settings),
            conversation_episode_count: conversation_episode_count(input),
            input: input,
            input_entry: entry
          }

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> transaction_result()
  end

  @spec validate(Context.t(), Decision.t()) ::
          {:ok, %{candidate: Candidate.t() | nil, decision: Decision.t()}} | {:error, term()}
  def validate(%Context{} = context, decision) do
    with {:ok, decision} <- Decision.prepare(decision),
         {:ok, candidate} <- selected_candidate(context, decision.episode_ref),
         :ok <- allowed_relation(candidate, decision.relation) do
      {:ok, %{candidate: candidate, decision: decision}}
    end
  end

  def validate(_context, _decision), do: {:error, {:admission_rejected, :context}}

  @type commit_result :: %{
          entry: Entry.t(),
          episode: Episode.t() | nil,
          status: :applied | :duplicate,
          transitions: [Responder.Episodes.Transition.t()]
        }

  @spec commit(Context.t(), Decision.t(), String.t()) ::
          {:ok, commit_result()} | {:error, term()}
  def commit(%Context{} = context, decision, decision_ref) do
    with {:ok, decision} <- Decision.prepare(decision),
         :ok <- validate_reference(decision_ref) do
      Repo.transaction(fn ->
        commit_in_transaction(context, decision, decision_ref)
      end)
      |> transaction_result()
    end
  end

  def commit(_context, _decision, _decision_ref),
    do: {:error, {:admission_rejected, :context}}

  defp commit_in_transaction(context, decision, decision_ref) do
    with {:ok, entry} <- load_entry(context.input_entry.id),
         {:ok, result} <- commit_locked(entry, context, decision, decision_ref) do
      result
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_options(options) when is_list(options) do
    now = Keyword.get(options, :now)
    continuation_window = Keyword.get(options, :continuation_window)
    history_window = Keyword.get(options, :history_window)
    candidate_limit = Keyword.get(options, :candidate_limit, 8)

    cond do
      not utc_datetime?(now) ->
        {:error, {:invalid_admission_context, :now}}

      not positive_integer?(continuation_window) ->
        {:error, {:invalid_admission_context, :continuation_window}}

      not positive_integer?(history_window) or history_window < continuation_window ->
        {:error, {:invalid_admission_context, :history_window}}

      not is_integer(candidate_limit) or candidate_limit < 1 or candidate_limit > 20 ->
        {:error, {:invalid_admission_context, :candidate_limit}}

      true ->
        {:ok,
         %{
           candidate_limit: candidate_limit,
           continuation_window: continuation_window,
           history_window: history_window,
           now: now
         }}
    end
  end

  defp validate_options(_options), do: {:error, {:invalid_admission_context, :options}}

  defp pending(%{status: :pending}), do: :ok

  defp pending(%{status: :decided, decision_ref: decision_ref}),
    do: {:error, {:input_already_decided, decision_ref}}

  defp input_from_entry(entry) do
    Input.new(%{
      actor: %{kind: entry.actor_kind, ref: entry.actor_ref},
      channel_ref: entry.channel_ref,
      content: entry.content,
      event_kind: entry.event_kind,
      event_ref: entry.event_ref,
      message_ref: entry.message_ref,
      occurred_at: entry.occurred_at,
      revision: entry.revision,
      thread_ref: entry.thread_ref,
      workspace_ref: entry.workspace_ref
    })
  end

  defp load_entry(id) do
    case Repo.one(from(entry in Entry, where: entry.id == ^id, lock: "FOR UPDATE")) do
      nil -> {:error, {:admission_rejected, :input_not_found}}
      entry -> {:ok, entry}
    end
  end

  defp commit_locked(
         %Entry{status: :decided} = entry,
         _context,
         decision,
         decision_ref
       ) do
    submitted = Decision.fingerprint(decision)

    if entry.decision_ref == decision_ref and entry.decision_fingerprint == submitted do
      {:ok,
       %{
         entry: entry,
         episode: load_decided_episode(entry.episode_id),
         status: :duplicate,
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
         %Entry{status: :pending} = entry,
         context,
         decision,
         decision_ref
       ) do
    with :ok <- same_input(entry, context),
         {:ok, selection} <- validate(context, decision),
         :ok <- current_creation_scope(context, selection),
         {:ok, transitions, episode} <- apply_episode(context, entry, selection),
         {:ok, decided} <- persist_decision(entry, decision, decision_ref, episode) do
      {:ok, %{entry: decided, episode: episode, status: :applied, transitions: transitions}}
    end
  end

  defp current_creation_scope(%Context{} = context, selection) do
    selection
    |> creates_episode?()
    |> creation_scope(context)
  end

  defp creation_scope(false, _context), do: :ok

  defp creation_scope(true, context) do
    with :ok <- lock_conversation(context.input) do
      compare_conversation_generation(context)
    end
  end

  defp compare_conversation_generation(context) do
    if conversation_episode_count(context.input) == context.conversation_episode_count,
      do: :ok,
      else: {:error, {:admission_rejected, :context_stale}}
  end

  defp creates_episode?(%{decision: %{action: action}} = selection)
       when action in [:start_episode, :reply],
       do: is_nil(existing_episode(selection))

  defp creates_episode?(_selection), do: false

  defp lock_conversation(input) do
    destination = Input.destination(input)

    case Repo.query(
           "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
           ["slack-admission:#{destination.conversation_ref}"]
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:store_failed, :conversation_lock, reason}}
    end
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

    with {:ok, [admitted]} <- Episodes.apply_batch_in_transaction([admit]),
         {:ok, resumed} <- maybe_resume_wait(context, selection, admit, admitted.episode) do
      transitions = [admitted | resumed]
      {:ok, transitions, transitions |> List.last() |> Map.fetch!(:episode)}
    end
  end

  defp admit_command(context, entry, selection) do
    existing = existing_episode(selection)
    input = context.input
    turn_ref = "slack-turn:#{entry.id}"

    %Command.AdmitInput{
      actor_ref: Input.actor_ref(input),
      destination: target_destination(input, existing),
      episode_id: if(existing, do: existing.id, else: entry.id),
      episode_key: if(existing, do: existing.key, else: "slack-input:#{entry.id}"),
      linked_episode_id: linked_episode(selection, existing),
      native_input_id: Input.message_key(input),
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

  defp target_destination(input, nil), do: Input.destination(input)

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

  defp load_decided_episode(nil), do: nil
  defp load_decided_episode(id), do: Repo.get(Episode, id)

  defp candidates(input, settings) do
    destination = Input.destination(input)
    history_cutoff = DateTime.add(settings.now, -settings.history_window, :second)

    episodes =
      Repo.all(
        from(episode in Episode,
          where:
            episode.destination_transport == "slack" and
              episode.destination_conversation_ref == ^destination.conversation_ref,
          where:
            episode.destination_thread_ref == ^destination.thread_ref or
              episode.state in ^@active_states or episode.updated_at >= ^history_cutoff,
          order_by: [
            desc: fragment("? = ?", episode.destination_thread_ref, ^destination.thread_ref),
            desc: episode.updated_at,
            asc: episode.id
          ],
          limit: ^settings.candidate_limit
        )
      )

    endpoints_by_episode = input_event_endpoints(Enum.map(episodes, & &1.id))

    Enum.map(episodes, fn episode ->
      Candidate.new(
        episode,
        Map.get(endpoints_by_episode, episode.id, %{}),
        destination.thread_ref,
        settings.now,
        settings.continuation_window
      )
    end)
  end

  defp conversation_episode_count(input) do
    destination = Input.destination(input)

    Repo.aggregate(
      from(episode in Episode,
        where:
          episode.destination_transport == "slack" and
            episode.destination_conversation_ref == ^destination.conversation_ref
      ),
      :count
    )
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
        order_by: [asc: event.occurred_at, asc: event.dedupe_key],
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
        order_by: [desc: event.occurred_at, desc: event.dedupe_key],
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

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp utc_datetime?(%DateTime{} = value) do
    value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0
  end

  defp utc_datetime?(_value), do: false
end
