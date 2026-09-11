defmodule Responder.Work.SubmissionBuilder do
  @moduledoc """
  Compiles one self-contained first briefing or compact same-session delta.

  The resulting `Submission` is frozen before any Coop mutation. Retries read
  its exact prompt and schema bytes from PostgreSQL rather than rebuilding them
  after code or configuration changes.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes.{Episode, Event, Reactions}
  alias Responder.GitHub.SourceRef, as: GitHubSourceRef
  alias Responder.Ingress.RecallText
  alias Responder.Repo
  alias Responder.Slack.SourceRef, as: SlackSourceRef

  alias Responder.State.{
    Behaviors,
    Continuity,
    DerivedContext,
    LearningSources,
    Memories,
    Outcomes,
    Records
  }

  alias Responder.StateTools.FixedTools
  alias Responder.StateTools.ToolVisibility
  alias Responder.Work.{Final, Prompt, Session, Submission, Turn}

  @maximum_inputs 40
  @maximum_context_bytes 160 * 1_024
  @input_content_bytes 1_024
  @continuity_content_bytes 256
  @record_payload_bytes 2_048
  @default_state_tool_capabilities [:event_waits, :publication, :schedules]
  @state_tool_capabilities [:emisar_approvals, :event_waits, :publication, :schedules]
  @truncation_marker "...<truncated>..."

  @doc """
  The frozen submission for this claim.

  Callers that only need the exact bytes to submit use this; `prepare/2`
  additionally returns the selection ledger, which is evidence about the
  selection rather than part of it.
  """
  @spec build(%{episode: Episode.t(), session: Session.t(), turn: Turn.t()}, keyword()) ::
          {:ok, Submission.t()} | {:error, term()}
  def build(claim, options \\ []) do
    case prepare(claim, options) do
      {:ok, %{submission: submission}} -> {:ok, submission}
      {:error, _reason} = error -> error
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
  @spec prepare(%{episode: Episode.t(), session: Session.t(), turn: Turn.t()}, keyword()) ::
          {:ok, %{submission: Submission.t(), ledger: map()}} | {:error, term()}
  def prepare(claim, options \\ [])

  def prepare(
        %{episode: %Episode{} = episode, session: %Session{} = session, turn: %Turn{} = turn},
        options
      )
      when is_list(options) do
    with :ok <- active_ref_count_fits(episode.active_input_refs),
         snapshot <- input_snapshot(episode),
         :ok <- active_inputs_present(snapshot.active, episode.active_input_refs),
         previous <- previous_turn(episode.id, turn.id),
         records <- Records.model_records(episode, session.repository_ref),
         {:ok, metadata} <- context_metadata(episode, options),
         {:ok, context, eligible} <-
           submission_context(episode, session, snapshot, records, previous, metadata),
         {:ok, submission} <-
           Submission.new(
             context,
             Prompt.build(context),
             Final.json_schema(),
             "work-final-v1",
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

  defp context_metadata(episode, options) do
    with {:ok, state_tools} <- state_tool_names(episode, options),
         {:ok, platform_tools} <- platform_tool_names(episode, options),
         {:ok, workspace} <- workspace(options) do
      # Capture required fields once so history fitting reserves their exact bytes.
      metadata = %{
        "custom_instructions" =>
          Responder.Instructions.snapshot(%{
            transport: episode.destination_transport,
            conversation_ref: episode.destination_conversation_ref
          }),
        "conversation_feedback" => Reactions.model_context(episode.id, episode.next_sequence),
        "responder_state_tools" => state_tools,
        "source_and_action_tools" => platform_tools
      }

      {:ok, maybe_put_workspace(metadata, workspace)}
    end
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

  defp platform_tool_names(episode, options) do
    configured =
      case Keyword.fetch(options, :platform_tools) do
        {:ok, tools} ->
          tools

        :error ->
          case Application.get_env(:responder, :state_tools, %{}) do
            %{additional_tools: tools} ->
              tools

            configuration when is_list(configuration) ->
              Keyword.get(configuration, :additional_tools, [])

            _configuration ->
              []
          end
      end

    if is_list(configured) do
      configured_names =
        configured
        |> Enum.map(fn
          %{"name" => name} when is_binary(name) -> name
          name when is_binary(name) -> name
          _invalid -> nil
        end)

      if Enum.all?(configured_names, &is_binary/1) and
           configured_names == Enum.uniq(configured_names),
         do:
           {:ok,
            Enum.filter(
              configured_names,
              &ToolVisibility.visible?(&1, episode.destination_transport)
            )},
         else: {:error, {:invalid_work_submission_builder, :platform_tools}}
    else
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

  defp fit_memory(context, key) do
    notes = get_in(context, ["operator_context", "continuity", key]) || []

    if notes != [] and byte_size(CanonicalJSON.encode!(context)) > @maximum_context_bytes do
      context
      |> put_in(["operator_context", "continuity", key], Enum.drop(notes, -1))
      |> fit_memory(key)
    else
      context
    end
  end

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

  defp fit_full_context(
         episode,
         session,
         snapshot,
         records,
         previous,
         metadata
       ) do
    %{active: active, historical: historical, total_count: total_count} = snapshot

    selected =
      (active ++ historical)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.sequence)

    context = %{
      "destination" => destination(episode),
      "execution_mode" => Atom.to_string(episode.execution_mode),
      "inputs" => %{
        "items" => Enum.map(selected, &input_document(&1, episode)),
        "omitted_count" => total_count - length(selected)
      },
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
      "related_outcomes" => Outcomes.recall(episode, session.repository_ref)
    }

    context =
      if previous do
        case historical_delivery(previous, episode, session.repository_ref) do
          nil -> context
          delivery -> Map.put(context, "prior_outcome", delivery)
        end
      else
        context
      end

    {context, eligible} = context |> Map.merge(metadata) |> fit_optional_observations()
    context_bytes = context |> CanonicalJSON.encode!() |> byte_size()

    artifact_count = context |> model_artifact_refs() |> length()

    cond do
      context_bytes <= @maximum_context_bytes and artifact_count <= 5 ->
        {:ok, context, eligible}

      historical != [] ->
        fit_full_context(
          episode,
          session,
          %{snapshot | historical: tl(historical)},
          records,
          previous,
          metadata
        )

      artifact_count > 5 ->
        {:error, {:work_active_artifact_overflow, artifact_count, 5}}

      true ->
        {:error, {:work_active_input_bytes_overflow, context_bytes, @maximum_context_bytes}}
    end
  end

  defp continuation_context(episode, session, snapshot, records, previous, metadata) do
    delivery = historical_delivery(previous, episode, session.repository_ref)

    context = %{
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
        "items" => Enum.map(snapshot.active, &input_document(&1, episode)),
        "omitted_count" => 0
      },
      "destination" => destination(episode),
      "execution_mode" => Atom.to_string(episode.execution_mode),
      "mode" => "continuation",
      "operator_context" => operator_context(episode, snapshot, session.repository_ref),
      "parent_submission_ref" => previous.submission_fingerprint,
      "offer_confirmation_supported" => offer_confirmation_supported?(episode),
      "records" => Enum.map(records, &record_document/1),
      "repository_ref" => session.repository_ref
    }

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
    |> Enum.flat_map(fn item -> collect_artifact_refs(item["content"]) end)
    |> Enum.uniq()
  end

  defp collect_artifact_refs(%{"artifact_ref" => ref, "status" => "available"})
       when is_binary(ref),
       do: [ref]

  defp collect_artifact_refs(%{} = value) do
    value
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.flat_map(fn {_key, child} -> collect_artifact_refs(child) end)
  end

  defp collect_artifact_refs(value) when is_list(value),
    do: Enum.flat_map(value, &collect_artifact_refs/1)

  defp collect_artifact_refs(_value), do: []

  defp resume_cause(%Episode{active_input_refs: [_first | _rest]}, _previous), do: "new_input"

  defp resume_cause(
         %Episode{active_input_refs: []},
         %Turn{continuation: %{"kind" => "wait", "wait_kind" => "event"}}
       ),
       do: "deadline_elapsed"

  defp resume_cause(_episode, _previous), do: "host_continuation"

  defp offer_confirmation_supported?(%Episode{
         destination_transport: transport,
         execution_mode: :live
       })
       when transport in ["slack", "control_plane", "github"],
       do: true

  defp offer_confirmation_supported?(_episode), do: false

  defp state_tool_names(episode, options) do
    capabilities =
      Keyword.get(options, :state_tool_capabilities, @default_state_tool_capabilities)

    cond do
      is_nil(capabilities) ->
        {:ok, []}

      is_list(capabilities) and capabilities == Enum.uniq(capabilities) and
          Enum.all?(capabilities, &(&1 in @state_tool_capabilities)) ->
        names =
          FixedTools.list(capabilities: capabilities, binding: %{episode: episode})
          |> Enum.map(& &1["name"])
          |> maybe_add_emisar_approval(capabilities)

        {:ok, names}

      true ->
        {:error, {:invalid_work_submission_builder, :state_tool_capabilities}}
    end
  end

  defp maybe_add_emisar_approval(names, capabilities) do
    if :emisar_approvals in capabilities,
      do: names ++ ["record_emisar_approval"],
      else: names
  end

  defp input_snapshot(episode) do
    base =
      from(event in Event,
        where:
          event.episode_id == ^episode.id and event.kind == :input_admitted and
            event.sequence < ^episode.next_sequence
      )

    active_refs = Enum.uniq(episode.active_input_refs)
    queued_refs = Enum.uniq(episode.queued_input_refs)
    historical_slots = @maximum_inputs - length(active_refs)

    visible =
      if queued_refs == [] do
        base
      else
        from(event in base, where: event.dedupe_key not in ^queued_refs)
      end

    active =
      if active_refs == [] do
        []
      else
        Repo.all(
          from(event in visible,
            where: event.dedupe_key in ^active_refs,
            order_by: [asc: event.sequence]
          )
        )
      end

    historical =
      if historical_slots == 0 do
        []
      else
        query =
          if active_refs == [] do
            visible
          else
            from(event in visible, where: event.dedupe_key not in ^active_refs)
          end

        query
        |> order_by([event], desc: event.sequence)
        |> limit(^historical_slots)
        |> Repo.all()
        |> Enum.reverse()
      end

    %{
      active: active,
      first: Repo.one(from(event in visible, order_by: [asc: event.sequence], limit: 1)),
      historical: historical,
      total_count: Repo.aggregate(visible, :count)
    }
  end

  defp previous_turn(episode_id, turn_id) do
    Repo.one(
      from(turn in Turn,
        where:
          turn.episode_id == ^episode_id and turn.id != ^turn_id and
            not is_nil(turn.result_ref),
        order_by: [desc: turn.inserted_at, desc: turn.id],
        limit: 1
      )
    )
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

  defp input_document(event, episode) do
    command = event.payload
    current = event.dedupe_key in episode.active_input_refs
    sources = LearningSources.for_work_input(command["payload"])

    document =
      %{
        "actor_ref" => command["actor_ref"],
        "content" =>
          if(current,
            do: command["payload"],
            else: compact_value(command["payload"], @input_content_bytes)
          ),
        "current" => current,
        "occurred_at" => DateTime.to_iso8601(event.occurred_at),
        "revision" => command["revision"]
      }
      |> put_source_ref(command["payload"])
      |> Map.put_new("source_ref", event.dedupe_key)

    source_linked_input(event, document, sources, not current)
  end

  defp put_source_ref(
         document,
         %{
           "destination" => %{"conversation_ref" => "slack:" <> rest},
           "source" => %{"kind" => "slack", "ref" => workspace_ref},
           "source_item_ref" => message_ref
         }
       )
       when is_binary(message_ref) do
    case String.split(rest, ":", parts: 2) do
      [^workspace_ref, channel_ref] ->
        Map.put(
          document,
          "source_ref",
          SlackSourceRef.message(workspace_ref, channel_ref, message_ref)
        )

      _invalid ->
        document
    end
  rescue
    _error -> document
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
          {id, ""} -> Map.put(document, "source_ref", GitHubSourceRef.item(binding, kind, id))
          _invalid -> document
        end

      _invalid ->
        document
    end
  rescue
    _error -> document
  end

  defp put_source_ref(document, _payload), do: document

  defp continuity_input(nil), do: nil

  defp continuity_input(event) do
    sources = LearningSources.for_work_input(event.payload["payload"])

    document =
      %{
        "actor_ref" => event.payload["actor_ref"],
        "content" => compact_value(event.payload["payload"], @continuity_content_bytes),
        "occurred_at" => DateTime.to_iso8601(event.occurred_at)
      }
      |> put_source_ref(event.payload["payload"])
      |> Map.put_new("source_ref", event.dedupe_key)

    source_linked_input(event, document, sources, true)
  end

  defp source_linked_input(event, document, nil, historical?) do
    case LearningSources.deleted_work_input(event, not historical?) do
      %{} = notice -> notice
      nil when historical? -> LearningSources.withdrawn_work_input(event)
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
    input_texts = Enum.map(snapshot.active, &RecallText.from(&1.payload["payload"]))

    operator_ref =
      events
      |> List.last()
      |> case do
        %Event{payload: %{"actor_ref" => actor_ref}} when is_binary(actor_ref) -> actor_ref
        _missing -> nil
      end

    episode
    |> Behaviors.model_context(operator_ref, repository)
    |> Map.put("memory", Memories.model_context(episode, repository))
    |> Map.put("continuity", Continuity.model_context(episode, repository, input_texts))
  end

  defp trusted_repository(events) do
    events
    |> Enum.reverse()
    |> Enum.find_value(&trusted_repository_from_event/1)
  end

  defp trusted_repository_from_event(%Event{payload: %{"payload" => payload}})
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

  defp record_document(record) do
    %{
      "kind" => record["kind"],
      "payload" => compact_value(record["payload"], @record_payload_bytes),
      "ref" => record["ref"],
      "status" => record["status"]
    }
  end

  defp historical_delivery(turn, episode, repository) do
    document = DerivedContext.delivery_document(turn)

    case DerivedContext.filter([DerivedContext.delivery(document)], episode, repository) do
      [_] -> document
      [] -> nil
    end
  end

  defp compact_value(nil, _maximum), do: nil

  defp compact_value(value, maximum) do
    encoded = CanonicalJSON.encode!(value)

    if byte_size(encoded) <= maximum do
      value
    else
      %{
        "json_preview" => bounded_preview(encoded, maximum),
        "original_bytes" => byte_size(encoded),
        "sha256" => digest(encoded),
        "truncated" => true
      }
    end
  end

  defp bounded_preview(encoded, maximum) do
    available = maximum - byte_size(@truncation_marker)
    head_bytes = div(available, 2)
    tail_bytes = available - head_bytes

    String.byte_slice(encoded, 0, head_bytes) <>
      @truncation_marker <> String.byte_slice(encoded, -tail_bytes, tail_bytes)
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
