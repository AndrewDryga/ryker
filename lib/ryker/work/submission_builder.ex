defmodule Ryker.Work.SubmissionBuilder do
  @moduledoc """
  Compiles one self-contained first briefing or compact same-session delta.

  The resulting `Submission` is frozen before any Coop mutation. Retries read
  its exact prompt and schema bytes from PostgreSQL rather than rebuilding them
  after code or configuration changes.
  """
  alias Ryker.Artifacts
  alias Ryker.Behaviors
  alias Ryker.CanonicalJSON
  alias Ryker.Continuity
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.GitHub
  alias Ryker.Ingress
  alias Ryker.Learning
  alias Ryker.Memories
  alias Ryker.People
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.RepositoryKnowledge
  alias Ryker.Slack
  alias Ryker.StateTools
  alias Ryker.Work.{Contract, PlatformTools, Prompt, Session, Submission, Turn}

  @maximum_inputs 40
  @retained_cases 3
  @maximum_context_bytes 160 * 1_024
  @input_content_bytes 1_024

  @doc """
  The frozen submission for this claim.

  Callers that only need the exact bytes to submit use this; `prepare/2`
  additionally returns the selection ledger, which is evidence about the
  selection rather than part of it.
  """
  @spec build(%{episode: Episodes.Episode.t(), session: Session.t(), turn: Turn.t()}, keyword()) ::
          {:ok, Submission.t()} | {:error, term()}
  def build(claim, options \\ []) do
    case prepare(claim, options) do
      {:ok, %{submission: submission}} -> {:ok, submission}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The frozen submission plus the ledger of what this turn actually selected.

  The context keeps the items that reached the model and one omitted total. It
  cannot say how many inputs were eligible, how many fell outside the history
  window, and how many were cut to fit; those are measured here, while the
  selection is being made, and frozen beside the submission. The ledger never
  enters the submission, so the prompt bytes and their fingerprint are
  identical with or without it.
  """
  @spec prepare(%{episode: Episodes.Episode.t(), session: Session.t(), turn: Turn.t()}, keyword()) ::
          {:ok, %{submission: Submission.t(), ledger: map()}} | {:error, term()}
  def prepare(claim, options \\ [])

  def prepare(
        %{
          episode: %Episodes.Episode{} = episode,
          session: %Session{} = session,
          turn: %Turn{} = turn
        },
        options
      )
      when is_list(options) do
    with :ok <- active_ref_count_fits(episode.active_input_refs),
         snapshot <- input_snapshot(episode),
         :ok <- active_inputs_present(snapshot.active, episode.active_input_refs),
         previous <- previous_turn(episode.id, turn.id),
         {:ok, contract} <- Contract.select(episode.execution_mode),
         :ok <- Contract.authorize_continuation(contract, previous, session),
         records <- Records.model_records(episode, session.repository_ref),
         {:ok, metadata} <- context_metadata(episode, session, contract.mode, options),
         {:ok, context, eligible} <-
           submission_context(episode, session, snapshot, records, previous, metadata),
         {:ok, submission} <-
           Submission.new(
             context,
             Prompt.build(context, contract.mode),
             contract.output_schema,
             contract.contract_version,
             model_artifact_refs(context)
           ) do
      {:ok, %{submission: submission, ledger: ledger(context, snapshot, eligible)}}
    end
  end

  def prepare(_claim, _options), do: {:error, {:invalid_work_submission_builder, :claim}}

  # Every count carries the scope it was measured over. Eligible is every
  # visible input for this episode; the window is the bounded set the builder
  # offered itself; included is what survived fitting. Omitted is therefore
  # two distinct facts -- outside the window, and cut to fit -- which one
  # stored total could never separate.
  defp ledger(%{"mode" => "full"} = context, snapshot, eligible) do
    items = get_in(context, ["inputs", "items"]) || []
    current = Enum.count(items, & &1["current"])
    earlier = length(items) - current
    offered = length(snapshot.active) + length(snapshot.historical)

    %{
      "version" => 1,
      "mode" => "full",
      "inputs" => %{
        "eligible" => snapshot.total_count,
        "current" => current,
        "earlier_included" => earlier,
        "omitted_window" => max(snapshot.total_count - offered, 0),
        "omitted_fit" => max(offered - length(items), 0)
      },
      "limits" => limits()
    }
    |> Map.merge(optional_counts(context, eligible))
  end

  defp ledger(%{"mode" => "continuation"} = context, snapshot, eligible) do
    items = get_in(context, ["current_inputs", "items"]) || []

    %{
      "version" => 1,
      "mode" => "continuation",
      "inputs" => %{
        "current" => length(items),
        # Earlier messages are not resent in a same-session update. They are not
        # budget omissions and must never be counted as any kind of loss.
        "earlier_not_resent" => max(snapshot.total_count - length(items), 0)
      },
      "limits" => limits()
    }
    |> Map.merge(optional_counts(context, eligible))
  end

  defp ledger(_context, _snapshot, _eligible), do: %{"version" => 1}

  defp optional_counts(context, eligible) do
    for {key, path} <- [
          {"observations", ["operator_context", "continuity", "observations"]},
          {"knowledge", ["operator_context", "continuity", "knowledge"]},
          {"records", ["records"]},
          {"related_outcomes", ["related_outcomes"]},
          {"guidance", ["operator_context", "guidance"]},
          {"memory", ["operator_context", "memory"]},
          {"standing_assignments", ["operator_context", "standing_assignments"]}
        ],
        included = get_in(context, path),
        is_list(included),
        into: %{} do
      counts = %{"included" => length(included)}

      {key,
       case Map.fetch(eligible, key) do
         {:ok, offered} -> Map.put(counts, "eligible", offered)
         :error -> counts
       end}
    end
  end

  defp limits do
    %{
      "max_inputs" => @maximum_inputs,
      "context_bytes" => @maximum_context_bytes,
      "input_content_bytes" => @input_content_bytes
    }
  end

  defp context_metadata(episode, session, mode, options) do
    with {:ok, state_tools} <- state_tool_names(episode, options),
         {:ok, platform_tools} <- platform_tool_names(episode, mode, options),
         {:ok, workspace} <- workspace(options) do
      # Capture required fields once so history fitting reserves their exact bytes.
      metadata = %{
        "custom_instructions" =>
          Ryker.Instructions.snapshot(%{
            transport: episode.destination_transport,
            conversation_ref: episode.destination_conversation_ref
          }),
        "conversation_feedback" =>
          Episodes.Reactions.model_context(episode.id, episode.next_sequence),
        "episode_title" => Episodes.RoutingDigests.titles([episode.id])[episode.id],
        "controller_tools" => state_tools,
        "source_and_action_tools" => platform_tools
      }

      {:ok,
       metadata
       |> maybe_put_workspace(workspace)
       |> maybe_put_connected(session, Keyword.get(options, :connected))}
    end
  end

  # What Ryker can reach from this conversation, so the model can say "GitHub
  # isn't connected here" instead of guessing from tool names and describing
  # its own machinery. Slack and GitHub are what the running system connected;
  # the Emisar account and repositories are this work's environment.
  defp maybe_put_connected(context, _session, nil), do: context

  defp maybe_put_connected(context, session, %{github: github, slack: slack}) do
    repository_context = session.repository_context || %{}

    repositories =
      [repository_context["primary_repository"] || session.repository_ref]
      |> Enum.concat(List.wrap(repository_context["read_only_repositories"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Map.put(context, "connected", %{
      "emisar" => not is_nil(session.emisar_connection_ref),
      "github" => github,
      "repositories" => repositories,
      "slack" => slack
    })
  end

  defp workspace(options) do
    case Keyword.fetch(options, :workspace) do
      :error ->
        {:ok, nil}

      {:ok, %{} = workspace} ->
        case CanonicalJSON.validate(workspace, max_bytes: 16 * 1_024) do
          :ok -> {:ok, workspace}
          {:error, _reason} -> {:error, {:invalid_work_submission_builder, :workspace}}
        end

      {:ok, _invalid} ->
        {:error, {:invalid_work_submission_builder, :workspace}}
    end
  end

  defp maybe_put_workspace(context, nil), do: context
  defp maybe_put_workspace(context, workspace), do: Map.put(context, "workspace", workspace)

  # The platform tools Work was assembled with (`Ryker.Runtime.Assembly`).
  defp platform_tool_names(episode, mode, options) do
    case PlatformTools.names(Keyword.get(options, :platform_tools)) do
      {:ok, names} ->
        {:ok,
         Enum.filter(
           names,
           &StateTools.ToolVisibility.visible?(&1, episode.destination_transport, mode)
         )}

      :error ->
        {:error, {:invalid_work_submission_builder, :platform_tools}}
    end
  end

  # Optional notes are dropped from the tail to fit. The count before the drop
  # is the only place the eligible total exists, so it is measured here.
  defp fit_optional_observations(context) do
    eligible =
      for key <- ["observations", "knowledge"],
          notes = get_in(context, ["operator_context", "continuity", key]),
          is_list(notes),
          into: %{},
          do: {key, length(notes)}

    {context |> fit_memory("observations") |> fit_memory("knowledge"), eligible}
  end

  # The notes kept are the longest head of the list that fits. Canonical JSON
  # puts only a comma between a list's items, so the briefing with its first
  # k notes is the briefing with none, plus each of theirs, plus k - 1 commas,
  # and each note is measured once. The whole briefing, up to 160 KiB, was
  # encoded again for every note dropped (2026-10-04 review).
  defp fit_memory(context, key) do
    path = ["operator_context", "continuity", key]

    case get_in(context, path) do
      [_ | _] = notes ->
        room = @maximum_context_bytes - encoded_size(put_in(context, path, []))
        put_in(context, path, fitting_head(notes, room))

      _none ->
        context
    end
  end

  defp fitting_head(notes, room) do
    notes
    |> Enum.reduce_while({[], -1}, fn note, {kept, used} ->
      used = used + 1 + encoded_size(note)
      if used <= room, do: {:cont, {[note | kept], used}}, else: {:halt, {kept, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp encoded_size(value), do: value |> CanonicalJSON.encode!() |> byte_size()

  defp submission_context(episode, session, snapshot, records, nil, metadata),
    do: fit_full_context(episode, session, snapshot, records, nil, metadata)

  defp submission_context(
         episode,
         session,
         snapshot,
         records,
         %{session_id: session_id} = previous,
         metadata
       )
       when session_id == session.id,
       do: continuation_context(episode, session, snapshot, records, previous, metadata)

  defp submission_context(episode, session, snapshot, records, previous, metadata),
    do: fit_full_context(episode, session, snapshot, records, previous, metadata)

  # What is remembered for a turn is chosen once: recall counts what it gives,
  # and a briefing too big for its budget used to be rebuilt whole for every
  # message it dropped, so one turn counted each fact as recalled once per
  # rebuild (27 times in the regression test, 2026-09-28). Fitting now trims
  # only the messages.
  defp fit_full_context(episode, session, snapshot, records, previous, metadata) do
    %{active: active, historical: historical} = snapshot
    origins = Episodes.Origins.for_episode(episode.id) |> Map.new(&{&1.input_ref, &1})
    notes = routing_notes(episode)

    context =
      %{
        "destination" => destination(episode),
        "origins" => origin_summary(episode, origins),
        "signals" => signal_summary(episode),
        "conversation_context" => admission_backdrop(episode),
        "retained_cases" => Memories.Cases.recall(episode, @retained_cases),
        "linked_history_ref" => episode.linked_episode_id,
        "mode" => "full",
        "operator_context" =>
          operator_context(
            episode,
            %{active: active, historical: historical},
            session.repository_ref
          ),
        "offer_confirmation_supported" => offer_confirmation_supported?(episode),
        "records" => Enum.map(records, &record_document/1),
        "repository_ref" => session.repository_ref,
        "related_outcomes" => Records.Outcomes.recall(episode, session.repository_ref)
      }
      |> maybe_put_repository_knowledge(session.repository_ref)
      |> put_prior_outcome(previous, episode, session.repository_ref)
      |> Map.merge(metadata)

    fit_inputs(context, snapshot, &input_document(&1, episode, origins, notes))
  end

  defp put_prior_outcome(context, nil, _episode, _repository), do: context

  defp put_prior_outcome(context, previous, episode, repository) do
    case historical_delivery(previous, episode, repository) do
      nil -> context
      delivery -> Map.put(context, "prior_outcome", delivery)
    end
  end

  # The earlier messages go oldest first until the briefing fits with no
  # optional notes, and then as many notes as fit go back in: a note never
  # costs a message. Dropping a message never makes the briefing bigger, so
  # the fewest to drop is found by halving. They were dropped one at a time,
  # each try fitting every note again, so a long conversation over budget
  # encoded the whole briefing once per message per note (2026-10-04 review).
  defp fit_inputs(context, snapshot, document) do
    %{active: active, historical: historical} = snapshot

    documents =
      (active ++ historical) |> Enum.uniq_by(& &1.id) |> Map.new(&{&1.id, document.(&1)})

    bare = Enum.reduce(["observations", "knowledge"], context, &without_notes/2)
    measure = &measure_inputs(bare, snapshot, documents, &1)

    dropped =
      if fits?(measure.(0)), do: 0, else: fewest_dropped(1, length(historical), measure)

    case measure.(dropped) do
      %{bytes: bytes, artifacts: artifacts} = fit
      when bytes <= @maximum_context_bytes and artifacts <= 5 ->
        {fitted, eligible} =
          context |> Map.put("inputs", fit.inputs) |> fit_optional_observations()

        {:ok, fitted, eligible}

      %{artifacts: artifacts} when artifacts > 5 ->
        {:error, {:work_active_artifact_overflow, artifacts, 5}}

      %{bytes: bytes} ->
        {:error, {:work_active_input_bytes_overflow, bytes, @maximum_context_bytes}}
    end
  end

  defp without_notes(key, context) do
    path = ["operator_context", "continuity", key]
    if is_list(get_in(context, path)), do: put_in(context, path, []), else: context
  end

  # The briefing's size and artifacts with the oldest `dropped` earlier
  # messages left out and no optional notes.
  defp measure_inputs(bare, snapshot, documents, dropped) do
    %{active: active, historical: historical, total_count: total_count} = snapshot

    selected =
      (active ++ Enum.drop(historical, dropped))
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.sequence)

    inputs = %{
      "items" => Enum.map(selected, &Map.fetch!(documents, &1.id)),
      "omitted_count" => total_count - length(selected)
    }

    measured = Map.put(bare, "inputs", inputs)

    %{
      artifacts: measured |> model_artifact_refs() |> length(),
      bytes: encoded_size(measured),
      inputs: inputs
    }
  end

  defp fits?(%{bytes: bytes, artifacts: artifacts}),
    do: bytes <= @maximum_context_bytes and artifacts <= 5

  # The fewest of `low..high` earlier messages to drop for the briefing to
  # fit; `high`, all of them, when none is enough.
  defp fewest_dropped(low, high, _measure) when low >= high, do: high

  defp fewest_dropped(low, high, measure) do
    middle = div(low + high, 2)

    if fits?(measure.(middle)),
      do: fewest_dropped(low, middle, measure),
      else: fewest_dropped(middle + 1, high, measure)
  end

  defp continuation_context(episode, session, snapshot, records, previous, metadata) do
    delivery = historical_delivery(previous, episode, session.repository_ref)

    context =
      %{
        "continuity" => %{
          "first_input" => continuity_input(snapshot.first),
          "host_continuation" => %{
            "requested" => previous.continuation,
            "resume_cause" => resume_cause(episode, previous)
          },
          "previous_delivery" => if(delivery, do: delivery["delivery"]),
          "previous_turn_ref" => if(delivery, do: delivery["source_turn_ref"]),
          "prior_input_count" => snapshot.total_count
        },
        "current_inputs" => %{
          "items" =>
            Enum.map(
              snapshot.active,
              &input_document(
                &1,
                episode,
                Map.new(Episodes.Origins.for_episode(episode.id), fn origin ->
                  {origin.input_ref, origin}
                end),
                routing_notes(episode)
              )
            ),
          "omitted_count" => 0
        },
        "signals" => signal_summary(episode),
        "destination" => destination(episode),
        "mode" => "continuation",
        "operator_context" => operator_context(episode, snapshot, session.repository_ref),
        "parent_submission_ref" => previous.submission_fingerprint,
        "offer_confirmation_supported" => offer_confirmation_supported?(episode),
        "records" => Enum.map(records, &record_document/1),
        "repository_ref" => session.repository_ref
      }
      |> maybe_put_repository_knowledge(session.repository_ref)

    {context, eligible} = context |> Map.merge(metadata) |> fit_optional_observations()
    context_bytes = context |> CanonicalJSON.encode!() |> byte_size()

    if context_bytes <= @maximum_context_bytes,
      do: {:ok, context, eligible},
      else: {:error, {:work_active_input_bytes_overflow, context_bytes, @maximum_context_bytes}}
  end

  defp model_artifact_refs(%{"mode" => "full", "inputs" => %{"items" => items}}),
    do: artifact_refs_from_items(items)

  defp model_artifact_refs(%{
         "mode" => "continuation",
         "current_inputs" => %{"items" => items}
       }),
       do: artifact_refs_from_items(items)

  defp model_artifact_refs(_context), do: []

  defp artifact_refs_from_items(items) do
    items
    |> Enum.flat_map(&collect_artifact_refs(&1["content"]))
    |> Enum.uniq()
  end

  # A voice message or video reaches the model as the transcript beside it in
  # the input; Coop takes no audio or video file.
  defp collect_artifact_refs(%{"artifact_ref" => ref, "status" => "available"} = descriptor)
       when is_binary(ref) do
    if Artifacts.recording?(descriptor["media_type"]), do: [], else: [ref]
  end

  defp collect_artifact_refs(%{} = value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {_key, child} -> collect_artifact_refs(child) end)
  end

  defp collect_artifact_refs(value) when is_list(value),
    do: Enum.flat_map(value, &collect_artifact_refs/1)

  defp collect_artifact_refs(_value), do: []

  defp resume_cause(%Episodes.Episode{active_input_refs: [_first | _rest]}, _previous),
    do: "new_input"

  defp resume_cause(
         %Episodes.Episode{active_input_refs: []},
         %Turn{continuation: %{"kind" => "wait", "wait_kind" => "event"}}
       ),
       do: "deadline_elapsed"

  defp resume_cause(_episode, _previous), do: "host_continuation"

  defp offer_confirmation_supported?(%Episodes.Episode{
         destination_transport: transport,
         execution_mode: :live
       })
       when transport in ["slack", "control_plane", "github"],
       do: true

  defp offer_confirmation_supported?(_episode), do: false

  defp state_tool_names(episode, options) do
    capabilities =
      Keyword.get(options, :state_tool_capabilities, StateTools.Capabilities.default())

    cond do
      is_nil(capabilities) ->
        {:ok, []}

      StateTools.Capabilities.valid?(capabilities) ->
        names =
          StateTools.FixedTools.list(capabilities: capabilities, binding: %{episode: episode})
          |> Enum.map(& &1["name"])
          |> maybe_add_emisar_approval(capabilities, episode)

        {:ok, names}

      true ->
        {:error, {:invalid_work_submission_builder, :state_tool_capabilities}}
    end
  end

  defp maybe_add_emisar_approval(names, capabilities, episode) do
    if :emisar_approvals in capabilities and
         Contract.fixed_tool_allowed?(episode.execution_mode, "record_emisar_approval"),
       do: names ++ ["record_emisar_approval"],
       else: names
  end

  defp input_snapshot(episode) do
    base =
      episode.id
      |> Episodes.Event.Query.by_episode_id()
      |> Episodes.Event.Query.by_kind(:input_admitted)
      |> Episodes.Event.Query.before_sequence(episode.next_sequence)

    active_refs = Enum.uniq(episode.active_input_refs)
    queued_refs = Enum.uniq(episode.queued_input_refs)
    historical_slots = @maximum_inputs - length(active_refs)

    visible =
      if queued_refs == [],
        do: base,
        else: Episodes.Event.Query.excluding_dedupe_keys(base, queued_refs)

    active =
      if active_refs == [] do
        []
      else
        visible
        |> Episodes.Event.Query.by_dedupe_keys(active_refs)
        |> Episodes.Event.Query.ordered_by_sequence()
        |> Repo.all()
      end

    historical =
      if historical_slots == 0 do
        []
      else
        query =
          if active_refs == [],
            do: visible,
            else: Episodes.Event.Query.excluding_dedupe_keys(visible, active_refs)

        query
        |> Episodes.Event.Query.ordered_by_sequence_desc()
        |> Episodes.Event.Query.limit_to(historical_slots)
        |> Repo.all()
        |> Enum.reverse()
      end

    %{
      active: active,
      first:
        visible
        |> Episodes.Event.Query.ordered_by_sequence()
        |> Episodes.Event.Query.limit_to(1)
        |> Repo.one(),
      historical: historical,
      total_count: Repo.aggregate(visible, :count)
    }
  end

  defp previous_turn(episode_id, turn_id) do
    episode_id
    |> Turn.Query.by_episode_id()
    |> Turn.Query.excluding_ids([turn_id])
    |> Turn.Query.having_result()
    |> Turn.Query.ordered_by_recent()
    |> Turn.Query.limit_to(1)
    |> Repo.one()
  end

  defp active_ref_count_fits(active_refs) do
    active_count = active_refs |> MapSet.new() |> MapSet.size()

    if active_count <= @maximum_inputs,
      do: :ok,
      else: {:error, {:work_active_input_overflow, active_count, @maximum_inputs}}
  end

  defp active_inputs_present(events, active_refs) do
    event_refs = MapSet.new(events, & &1.dedupe_key)

    if MapSet.equal?(event_refs, MapSet.new(active_refs)),
      do: :ok,
      else: {:error, :work_active_input_missing}
  end

  # Every input says where it came from, so a briefing built from several
  # conversations stays readable and a direct answer can return to the exact
  # place its question was asked.
  defp input_document(event, episode, origins, notes) do
    command = event.payload
    current = current_input?(event, episode)
    sources = Learning.LearningSources.for_work_input(command["payload"])
    note = if current, do: Map.get(notes, routing_key(command["payload"]))

    document =
      %{
        "actor_ref" => command["actor_ref"],
        "origin" => origin_document(Map.get(origins, event.dedupe_key)),
        "content" =>
          if(current,
            do: command["payload"],
            else: CanonicalJSON.bounded(command["payload"], @input_content_bytes)
          ),
        "current" => current,
        "occurred_at" => DateTime.to_iso8601(event.occurred_at),
        "revision" => command["revision"]
      }
      |> put_source_ref(command["payload"])
      |> Map.put_new("source_ref", event.dedupe_key)
      |> then(&if(note, do: Map.put(&1, "routing_note", note), else: &1))

    source_linked_input(event, document, sources, not current)
  end

  # Work that stopped and is resumed by an edit keeps its first message beside
  # the edit, so both versions of one message can be current. Only the newest
  # is what the person says now. The older one's source moved to the edit, and
  # as current input it made every briefing stale: Andrew's edit stopped again
  # with each Retry (manual test, 2026-10-01). It is withdrawn instead.
  defp current_input?(%Episodes.Event{dedupe_key: ref, payload: command}, episode) do
    ref in episode.active_input_refs and
      Map.get(episode.input_revisions, command["native_input_id"], 0) <= command["revision"]
  end

  # Routing's own account of why each message came to this work: the action it
  # chose, its reason and the kind of work. Andrew asked (2026-09-26) that Work
  # see it; it is a first look that checked nothing, and the prompt says so.
  # An admitted input and its routing entry share the source and event ids.
  defp routing_notes(%Episodes.Episode{id: episode_id}) do
    episode_id
    |> Ingress.Inbox.Entry.Query.by_episode_id()
    |> Ingress.Inbox.Entry.Query.having_decision_document()
    |> Ingress.Inbox.Entry.Query.select_decisions()
    |> Repo.all()
    |> Enum.flat_map(fn {kind, ref, event_ref, decision} ->
      case routing_note(decision) do
        nil -> []
        note -> [{{kind, ref, event_ref}, note}]
      end
    end)
    |> Map.new()
  end

  defp routing_note(%{"action" => action, "reason" => reason} = decision)
       when is_binary(action) and is_binary(reason),
       do: %{"decision" => action, "reason" => reason, "work_class" => decision["work_class"]}

  defp routing_note(_decision), do: nil

  defp routing_key(%{"source" => %{"kind" => kind, "ref" => ref}, "event_ref" => event_ref}),
    do: {kind, ref, event_ref}

  defp routing_key(_payload), do: nil

  defp put_source_ref(
         document,
         %{
           "destination" => %{"conversation_ref" => "slack:" <> _rest = conversation_ref},
           "source" => %{"kind" => "slack", "ref" => workspace_ref},
           "source_item_ref" => message_ref
         }
       )
       when is_binary(message_ref) do
    case ConversationRef.parse_slack(conversation_ref) do
      {:ok, ^workspace_ref, channel_ref} ->
        Map.put(
          document,
          "source_ref",
          Slack.SourceRef.message(workspace_ref, channel_ref, message_ref)
        )

      _invalid ->
        document
    end
  rescue
    # SourceRef refuses an identity the platform malformed with ArgumentError,
    # and that input simply carries no source ref. Anything else is a host bug
    # and surfaces instead of silently dropping the ref.
    ArgumentError -> document
  end

  defp put_source_ref(
         document,
         %{
           "source" => %{"kind" => "github", "ref" => binding},
           "source_item_ref" => "github:" <> item
         }
       ) do
    case String.split(item, ":", parts: 2) do
      [kind, id] ->
        case Integer.parse(id) do
          {id, ""} -> Map.put(document, "source_ref", GitHub.SourceRef.item(binding, kind, id))
          _invalid -> document
        end

      _invalid ->
        document
    end
  rescue
    ArgumentError -> document
  end

  defp put_source_ref(document, _payload), do: document

  # The first briefing shows the same surrounding conversation the routing
  # decision was made against, read back from that decision's frozen snapshot.
  # A replacement session rebuilds the identical bytes instead of fetching a
  # newer transcript, so a retry cannot silently widen what Work was told.
  defp admission_backdrop(%Episodes.Episode{} = episode) do
    if routed_start?(episode),
      do: own_backdrop(episode),
      else: linked_backdrop(episode) || own_backdrop(episode)
  end

  defp own_backdrop(episode) do
    episode.id
    |> Ingress.Inbox.Entry.Query.by_episode_id()
    |> Ingress.Inbox.Entry.Query.having_admission_context()
    |> Ingress.Inbox.Entry.Query.ordered_by_occurred_at()
    |> Ingress.Inbox.Entry.Query.limit_to(1)
    |> Ingress.Inbox.Entry.Query.select_admission_contexts()
    |> Repo.one()
    |> backdrop()
  end

  # Routing starts an episode under the id of the message it admitted. A task starts when a
  # person confirms an offer, and nothing routed it.
  defp routed_start?(%Episodes.Episode{id: id}),
    do: Repo.exists?(Ingress.Inbox.Entry.Query.by_id(id))

  # A task's backdrop is the conversation it was offered in, as frozen when the latest message
  # that conversation had admitted before the task started arrived (Andrew, 2026-10-01: a task
  # "doesn't receive previous messages so it can lose important context"). Each admitted input
  # names its inbox entry; one admitted later, there or in the task, never changes it.
  defp linked_backdrop(%Episodes.Episode{linked_episode_id: linked, inserted_at: started})
       when is_binary(linked) and not is_nil(started) do
    entry_ids =
      linked
      |> Episodes.Event.Query.by_episode_id()
      |> Episodes.Event.Query.by_kind(:input_admitted)
      |> Episodes.Event.Query.inserted_by(started)
      |> Episodes.Event.Query.select_payloads()
      |> Repo.all()
      |> Enum.flat_map(fn payload ->
        with %{"turn_ref" => "ingress-turn:" <> id} <- payload,
             {:ok, entry_id} <- Ecto.UUID.cast(id) do
          [entry_id]
        else
          _host_input -> []
        end
      end)

    entry_ids
    |> Ingress.Inbox.Entry.Query.by_ids()
    |> Ingress.Inbox.Entry.Query.having_admission_context()
    |> Ingress.Inbox.Entry.Query.ordered_by_occurred_at_desc()
    |> Ingress.Inbox.Entry.Query.limit_to(1)
    |> Ingress.Inbox.Entry.Query.select_admission_contexts()
    |> Repo.one()
    |> backdrop()
  end

  defp linked_backdrop(_episode), do: nil

  defp backdrop(%{"conversation_context" => %{} = bundle} = snapshot),
    do: %{"bundle" => bundle, "manifest" => snapshot["context_manifest"]}

  defp backdrop(_absent), do: nil

  defp origin_document(nil), do: nil

  defp origin_document(origin) do
    %{
      "conversation_ref" => origin.conversation_ref,
      "kind" => Atom.to_string(origin.origin_kind),
      "thread_ref" => origin.thread_ref
    }
  end

  # One noisy conversation must not erase the material finding another one
  # contributed, so the briefing always states which conversations are in play.
  defp origin_summary(episode, origins) do
    home = Episodes.Origins.home(episode)

    %{
      "home" => %{
        "conversation_ref" => home.conversation_ref,
        "thread_ref" => home.thread_ref,
        "transport" => home.transport
      },
      "conversations" =>
        origins
        |> Map.values()
        |> Enum.map(& &1.conversation_ref)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  # Alert lifecycles stay individually tracked: recovering one signal never
  # states that the incident itself is resolved.
  defp signal_summary(episode) do
    claims = Episodes.CorrelationClaims.for_episode(episode.id)

    %{
      "active" => Enum.count(claims, &(&1.status == :active and &1.lifecycle_state == :active)),
      "terminal" =>
        Enum.count(claims, &(&1.status == :active and &1.lifecycle_state == :terminal)),
      "all_terminal" => claims != [] and Episodes.CorrelationClaims.all_terminal?(episode.id)
    }
  end

  defp continuity_input(nil), do: nil

  # The message that began the work, shortened as any earlier message is. A
  # shorter preview kept only a message's envelope: its sender and the start
  # of its block list, and none of its words.
  defp continuity_input(event) do
    sources = Learning.LearningSources.for_work_input(event.payload["payload"])

    document =
      %{
        "actor_ref" => event.payload["actor_ref"],
        "content" => CanonicalJSON.bounded(event.payload["payload"], @input_content_bytes),
        "occurred_at" => DateTime.to_iso8601(event.occurred_at)
      }
      |> put_source_ref(event.payload["payload"])
      |> Map.put_new("source_ref", event.dedupe_key)

    source_linked_input(event, document, sources, true)
  end

  defp source_linked_input(event, document, nil, historical?) do
    case Learning.LearningSources.deleted_work_input(event, not historical?) do
      %{} = notice -> notice
      nil when historical? -> Learning.LearningSources.withdrawn_work_input(event)
      nil -> put_work_sources(event, document, nil)
    end
  end

  defp source_linked_input(event, document, sources, _historical?),
    do: put_work_sources(event, document, sources)

  defp put_work_sources(event, document, sources) do
    # Active work with an unavailable source keeps a nil receipt so authorization
    # rejects it. Only historical context may become a no-prose tombstone.
    document
    |> Map.put("source_event_id", event.id)
    |> Map.put("source_dependencies", sources)
  end

  defp destination(episode) do
    %{
      "conversation_ref" => episode.destination_conversation_ref,
      "thread_ref" => episode.destination_thread_ref,
      "transport" => episode.destination_transport
    }
  end

  defp operator_context(episode, snapshot, pinned_repository) do
    events = snapshot.active ++ snapshot.historical
    repository = pinned_repository || trusted_repository(events)
    # Only inputs advanced into this turn may influence its topic selection.
    # Queued future instructions and unrelated recent topics are not a briefing.
    input_texts =
      for event <- snapshot.active,
          current_input?(event, episode),
          do: Ingress.RecallText.from(event.payload["payload"])

    operator_ref = asker(snapshot)

    episode
    |> Behaviors.model_context(operator_ref, repository)
    |> Map.put("memory", Memories.model_context(episode, repository))
    |> Map.put("continuity", Continuity.model_context(episode, repository, input_texts))
    |> put_person_asking(operator_ref, episode.destination_conversation_ref)
  end

  # Whom this turn answers: the sender of its newest input, or, for a turn with
  # no new input such as one an awaited event resumed, the last person who
  # spoke. Private rules, preferences and what someone said about themselves
  # follow this person; reading the earlier inputs last once handed a follow-up
  # from B everything private of A, who asked first (2026-10-04 review).
  defp asker(snapshot) do
    Enum.find_value([snapshot.active, snapshot.historical], fn events ->
      events
      |> Enum.reverse()
      |> Enum.find_value(fn
        %Episodes.Event{payload: %{"actor_ref" => actor_ref}} when is_binary(actor_ref) ->
          actor_ref

        _other ->
          nil
      end)
    end)
  end

  # What the person asking said about themselves (`Ryker.People`), with how to
  # use it; left out when nothing is known.
  defp put_person_asking(context, operator_ref, conversation_ref) do
    case People.model_context(People.about(operator_ref, conversation_ref)) do
      nil -> context
      person -> Map.put(context, "person_asking", person)
    end
  end

  defp trusted_repository(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&trusted_repository_from_event/1)
  end

  defp trusted_repository_from_event(%Episodes.Event{payload: %{"payload" => payload}})
       when is_map(payload) do
    case payload do
      %{"task" => %{"repository" => repository}} when is_binary(repository) ->
        repository

      %{
        "source" => %{"kind" => "github"},
        "content" => %{"payload" => %{"repository" => %{"full_name" => repository}}}
      }
      when is_binary(repository) ->
        repository

      %{
        "source" => %{"kind" => "schedule"},
        "content" => %{"schedule" => %{"repository" => repository}}
      }
      when is_binary(repository) ->
        repository

      _unscoped ->
        nil
    end
  end

  defp trusted_repository_from_event(_event), do: nil

  # Repository knowledge is copied into the frozen submission, not looked up by
  # the model at run time. A prepared turn therefore keeps the exact RYKER.md
  # it was briefed with even if the knowledge lane writes a newer one
  # meanwhile. Ryker keeps the document itself, and it is the repository's
  # knowledge the moment it is written (`Ryker.RepositoryKnowledge`); the
  # repository holds no copy, so no path in it is named.
  defp maybe_put_repository_knowledge(context, repository_ref) when is_binary(repository_ref) do
    case RepositoryKnowledge.fetch_entry(repository_ref) do
      {:ok, %{document: content, document_sha256: sha256, document_commit: commit}}
      when is_binary(content) ->
        Map.put(context, "repository_knowledge", %{
          "content" => content,
          "sha256" => sha256,
          "source_commit" => commit
        })

      _none ->
        context
    end
  end

  defp maybe_put_repository_knowledge(context, _repository_ref), do: context

  defp record_document(record) do
    %{
      "kind" => record["kind"],
      "payload" => Records.DerivedContext.record_payload(record["payload"]),
      "ref" => record["ref"],
      "status" => record["status"]
    }
  end

  defp historical_delivery(turn, episode, repository) do
    document = Records.DerivedContext.delivery_document(turn)

    case Records.DerivedContext.filter(
           [Records.DerivedContext.delivery(document)],
           episode,
           repository
         ) do
      [_] -> document
      [] -> nil
    end
  end
end
