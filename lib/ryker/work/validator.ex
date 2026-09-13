defmodule Ryker.Work.Validator do
  @moduledoc """
  Deterministic semantic admission for one universal final candidate.

  This validator gates only host-owned facts: references exist, an explicit
  human request is not silently dropped, and a waiting outcome names the exact
  durable wait that will resume it. It deliberately does not grade arbitrary
  prose, infer cause, or impose alert-specific checklists.
  """

  alias Ryker.Slack.Mentions
  alias Ryker.Work.{Final, Result}

  @context_fields ~w(artifact_delivery_supported artifact_metadata artifact_refs execution_mode open_required_goals records slack_mentions visible_reply_required workspace)
  @reference_regex ~r/\A[A-Za-z0-9_.:-]{1,256}\z/
  @shadow_record_kinds ~w(evidence coverage finding progress alert_assessment)

  @type accepted :: %{final: Final.t(), result: Result.t()}
  @type outcome :: {:accept, accepted()} | {:reject, [String.t()]} | {:error, term()}

  @spec validate(String.t(), map(), DateTime.t()) :: outcome()
  def validate(candidate, context, %DateTime{} = now) do
    with {:ok, context} <- prepare_context(context),
         {:ok, final} <- parse_candidate(candidate) do
      violations = semantic_violations(final, context, now)

      case violations do
        [] -> accept(final, context, now)
        [_first | _rest] -> {:reject, violations}
      end
    else
      {:reject, _violations} = rejection -> rejection
      {:error, _reason} = error -> error
    end
  end

  def validate(_candidate, _context, _now),
    do: {:error, {:invalid_work_validation_context, :now}}

  defp parse_candidate(candidate) when is_binary(candidate) do
    case Jason.decode(candidate) do
      {:ok, %{} = document} ->
        parse_final(document)

      {:ok, _other} ->
        reject(
          "Return one JSON object matching the attached output schema; the candidate is not a JSON object."
        )

      {:error, _reason} ->
        reject(
          "Return one JSON object matching the attached output schema; the candidate is not valid JSON."
        )
    end
  end

  defp parse_candidate(_candidate) do
    reject(
      "Return one JSON object matching the attached output schema; the candidate is not valid JSON."
    )
  end

  defp parse_final(document) do
    case Final.parse(document) do
      {:ok, final} -> {:ok, final}
      {:error, {:invalid_work_final, field}} -> reject(final_violation(field))
    end
  end

  defp semantic_violations(final, context, now) do
    []
    |> shadow_violations(final, context)
    |> mention_violations(final, context)
    |> visibility_violations(final, context)
    |> platform_action_violations(context)
    |> missing_record_violations(final, context)
    |> missing_artifact_violations(final, context)
    |> artifact_delivery_violations(final, context)
    |> abandoned_wait_violations(final, context)
    |> continuation_violations(final, context, now)
    |> workspace_violations(final, context)
    |> open_goal_violations(final, context)
    |> Enum.reverse()
  end

  defp shadow_violations(violations, final, %{execution_mode: :shadow, records: records}) do
    unsafe_refs =
      Enum.filter(final.record_refs, fn ref ->
        case Map.get(records, ref) do
          %{kind: kind} -> kind not in @shadow_record_kinds
          _missing -> false
        end
      end)

    violations =
      if final.delivery == :none do
        violations
      else
        [
          "This is an observe-only shadow evaluation. Set delivery to none and summarize what would have happened in decision_reason; nothing may be posted or reacted."
          | violations
        ]
      end

    if unsafe_refs == [] do
      violations
    else
      [
        "Remove effectful or waiting records from this shadow result: #{Enum.join(unsafe_refs, ", ")}. Shadow may retain only evidence, coverage, findings, progress, and alert assessments."
        | violations
      ]
    end
  end

  defp shadow_violations(violations, _final, _context), do: violations

  defp mention_violations(violations, %{message: nil}, _context), do: violations

  defp mention_violations(violations, %{message: message}, %{slack_mentions: authority}) do
    Mentions.violations(message, authority) ++ violations
  end

  defp open_goal_violations(violations, %{state: :complete}, %{open_required_goals: goals})
       when goals != [] do
    summary =
      goals
      |> Enum.take(5)
      |> Enum.map_join(", ", fn goal ->
        "#{goal.id} (#{goal.requested_outcome}; #{goal.state})"
      end)
      |> String.byte_slice(0, 3_000)

    [
      "Do not complete while required goals remain open: #{summary}. Continue the work, wait with a durable record, or call update_goal with completed, excluded, or cancelled for each goal before completing."
      | violations
    ]
  end

  defp open_goal_violations(violations, _final, _context), do: violations

  defp workspace_violations(violations, %{state: :complete}, %{workspace: workspace})
       when is_map(workspace) do
    violations
    |> dirty_workspace_violations(workspace)
    |> missing_engineering_change_violations(workspace)
  end

  defp workspace_violations(violations, _final, _context), do: violations

  defp dirty_workspace_violations(violations, workspace) do
    dirty =
      ~w(staged_count unstaged_count untracked_count conflict_count)
      |> Enum.map(&workspace[&1])
      |> Enum.sum()

    if dirty > 0 do
      [
        "Do not complete while the engineering workspace has #{dirty} uncommitted or conflicted path(s). Commit the intended task changes and return the corrected final in this same turn."
        | violations
      ]
    else
      violations
    end
  end

  defp missing_engineering_change_violations(violations, %{
         "admitted_source_tree" => admitted_source_tree,
         "fork_tree" => fork_tree
       })
       when is_binary(admitted_source_tree) do
    if fork_tree == admitted_source_tree do
      [
        "Do not complete: this workspace has no committed task changes beyond the admitted source it started from. Continue the implementation in this same turn."
        | violations
      ]
    else
      violations
    end
  end

  defp missing_engineering_change_violations(violations, %{"committed_count" => 0}) do
    [
      "Do not complete: this workspace has no committed task changes. Continue the implementation and commit the intended changes in this same turn."
      | violations
    ]
  end

  defp missing_engineering_change_violations(violations, _workspace), do: violations

  defp visibility_violations(
         violations,
         %{delivery: :none} = final,
         %{visible_reply_required: true} = context
       ) do
    if delivered_reaction_referenced?(final, context) do
      violations
    else
      [
        "Set delivery to reply and answer the user, or reference a delivered reaction addition covering the exact sole current human source item: an explicit human request cannot be silently discarded. Reaction removals, reactions to another item, and one reaction for multiple human inputs do not count."
        | violations
      ]
    end
  end

  defp visibility_violations(violations, _final, _context), do: violations

  defp platform_action_violations(violations, %{records: records}) do
    unresolved =
      records
      |> Enum.filter(fn {_ref, record} ->
        record.kind == "platform_action" and record.status != :delivered
      end)
      |> Enum.map(fn {ref, record} -> "#{ref} (#{record.status})" end)

    if unresolved == [] do
      violations
    else
      [
        "Do not complete while platform actions are unresolved: #{Enum.join(unresolved, ", ")}. Wait for delivery or use host recovery for a blocked action."
        | violations
      ]
    end
  end

  defp delivered_reaction_referenced?(final, context) do
    Enum.any?(final.record_refs, fn ref ->
      case context.records[ref] do
        %{
          action: :add,
          action_kind: :reaction,
          current_human_inputs: [%{source_item_ref: source_item_ref}],
          kind: "platform_action",
          source_item_ref: source_item_ref,
          status: :delivered
        }
        when is_binary(source_item_ref) ->
          true

        _other ->
          false
      end
    end)
  end

  defp missing_record_violations(violations, final, context) do
    Enum.reduce(final.record_refs, violations, fn ref, accumulated ->
      if Map.has_key?(context.records, ref) do
        accumulated
      else
        [
          "Remove outcome.record_refs entry #{inspect(ref)} or create that durable record first; no record with that host-issued reference exists in this episode."
          | accumulated
        ]
      end
    end)
  end

  defp missing_artifact_violations(violations, final, context) do
    Enum.reduce(final.artifact_refs, violations, fn ref, accumulated ->
      if MapSet.member?(context.artifact_refs, ref) do
        accumulated
      else
        [missing_artifact_violation(ref, context.artifact_metadata) | accumulated]
      end
    end)
  end

  defp missing_artifact_violation(ref, metadata) do
    case Enum.filter(metadata, &(&1.name == ref)) do
      [%{id: id}] ->
        "Replace outcome.artifact_refs entry #{inspect(ref)} with the host-issued reference #{inspect(id)}; the generated file exists under that exact reference."

      _missing_or_ambiguous ->
        "Remove outcome.artifact_refs entry #{inspect(ref)} or create that artifact first; no deliverable artifact with that host-issued reference exists in this episode."
    end
  end

  defp artifact_delivery_violations(
         violations,
         %{artifact_refs: [_first | _rest]},
         %{artifact_delivery_supported: false}
       ) do
    [
      "Remove outcome.artifact_refs from this response: the bound destination cannot deliver generated artifact bytes. Describe the result in the message instead."
      | violations
    ]
  end

  defp artifact_delivery_violations(violations, _final, _context), do: violations

  defp abandoned_wait_violations(violations, final, context) do
    referenced = MapSet.new(final.record_refs)

    abandoned =
      context.records
      |> Enum.flat_map(fn
        {ref, %{continuation: continuation}} when is_map(continuation) ->
          if continuation_kind(continuation) && not MapSet.member?(referenced, ref),
            do: [ref],
            else: []

        {_ref, _record} ->
          []
      end)
      |> Enum.sort()

    case abandoned do
      [] ->
        violations

      refs ->
        shown = refs |> Enum.take(5) |> Enum.map_join(", ", &inspect/1)
        remaining = length(refs) - min(length(refs), 5)
        suffix = if remaining > 0, do: ", and #{remaining} more", else: ""

        [
          "Open durable waits cannot be abandoned: #{shown}#{suffix}. Reference exactly one matching wait in outcome.record_refs and use its waiting state, or resolve that wait before completing."
          | violations
        ]
    end
  end

  defp continuation_violations(violations, final, context, now) do
    waits = final |> referenced_waits(context) |> primary_waits(final.state)

    case {final.state, waits} do
      {:complete, []} ->
        violations

      {:complete, [_first | _rest]} ->
        [
          "Set outcome.state to the matching waiting state or omit the wait record; complete cannot reference a pending durable wait."
          | violations
        ]

      {:waiting_for_input, [record]} ->
        validate_wait(violations, record, :input, now)

      {:waiting_for_event, [record]} ->
        validate_wait(violations, record, :event, now)

      {:waiting_for_input, []} ->
        [
          "outcome.state waiting_for_input requires exactly one referenced durable input wait created with request_input; no input wait was referenced."
          | violations
        ]

      {:waiting_for_event, []} ->
        [
          "outcome.state waiting_for_event requires exactly one referenced durable event wait created with wait_for or record_emisar_approval; no event wait was referenced."
          | violations
        ]

      {:waiting_for_input, waits} ->
        [
          "outcome.state waiting_for_input must reference exactly one durable input wait, but #{length(waits)} wait records were referenced."
          | violations
        ]

      {:waiting_for_event, waits} ->
        [
          "outcome.state waiting_for_event must reference exactly one durable event wait, but #{length(waits)} wait records were referenced."
          | violations
        ]
    end
  end

  # A question owns continuation while any number of event-only watches stay
  # armed beside it. This matched a two-element list, so an episode holding a
  # question and two open watches had no valid answer at all: referencing all
  # three failed "exactly one durable input wait", and dropping the extras
  # failed "open durable waits cannot be abandoned". Production hit it on
  # episode 0b0c3590 and burned the turn's three attempts against itself.
  defp primary_waits(waits, :waiting_for_input) do
    case Enum.split_with(waits, &(continuation_kind(&1.continuation) == :input)) do
      {[question], watches} ->
        if Enum.all?(watches, &event_only_watch?/1), do: [question], else: waits

      _other ->
        waits
    end
  end

  defp primary_waits(waits, _state), do: waits

  # A timed wait is a wait somebody must come back to, so it can never ride
  # along silently; only a deadline-free source watch can.
  defp event_only_watch?(%{
         kind: "event_wait",
         continuation: %{"wait_kind" => "event", "deadline_at" => nil}
       }),
       do: true

  defp event_only_watch?(_wait), do: false

  defp validate_wait(violations, %{continuation: continuation, ref: ref}, expected_kind, now) do
    actual_kind = continuation_kind(continuation)

    cond do
      actual_kind != expected_kind ->
        [
          "outcome.state waiting_for_#{expected_kind} must reference an #{expected_kind} wait, but #{inspect(ref)} is an #{actual_kind || :invalid} wait."
          | violations
        ]

      expected_kind == :event and elapsed?(continuation, now) ->
        [
          "The event wait #{inspect(ref)} has an elapsed or invalid deadline; create a new wait with wait_for or finish the response now."
          | violations
        ]

      true ->
        violations
    end
  end

  defp referenced_waits(final, context) do
    final.record_refs
    |> Enum.flat_map(fn ref ->
      case context.records[ref] do
        %{continuation: continuation, kind: kind} when is_map(continuation) ->
          [%{continuation: continuation, kind: kind, ref: ref}]

        _not_a_wait ->
          []
      end
    end)
    |> Enum.sort_by(&{continuation_kind(&1.continuation) != :input, &1.ref})
  end

  defp accept(final, context, now) do
    continuation = accepted_continuation(final, context)

    result =
      case final.delivery do
        :reply -> Result.new(:reply, Final.document(final), nil, continuation)
        :none -> Result.new(:none, nil, final.decision_reason, continuation)
      end

    with {:ok, result} <- result,
         :ok <- Result.validate_at(result, now) do
      {:accept, %{final: final, result: result}}
    else
      {:error, reason} -> {:error, {:work_validator_result_invalid, reason}}
    end
  end

  defp accepted_continuation(%{state: :complete}, _context), do: %{"kind" => "complete"}

  defp accepted_continuation(final, context) do
    [%{continuation: continuation} | _retained_watch] = referenced_waits(final, context)
    continuation
  end

  defp prepare_context(%{} = context) do
    with :ok <- exact_context_fields(context),
         true <- is_boolean(context["artifact_delivery_supported"]),
         true <- is_boolean(context["visible_reply_required"]),
         {:ok, execution_mode} <- execution_mode(context["execution_mode"]),
         {:ok, artifacts} <- prepare_artifacts(context["artifact_refs"]),
         {:ok, artifact_metadata} <-
           prepare_artifact_metadata(context["artifact_metadata"], artifacts),
         {:ok, goals} <- prepare_open_goals(context["open_required_goals"]),
         {:ok, records} <- prepare_records(context["records"]),
         {:ok, _mentions} <- Mentions.prepare_authority(context["slack_mentions"]),
         {:ok, workspace} <- prepare_workspace(context["workspace"]) do
      {:ok,
       %{
         artifact_delivery_supported: context["artifact_delivery_supported"],
         artifact_metadata: artifact_metadata,
         artifact_refs: artifacts,
         execution_mode: execution_mode,
         open_required_goals: goals,
         records: records,
         slack_mentions: context["slack_mentions"],
         visible_reply_required: context["visible_reply_required"],
         workspace: workspace
       }}
    else
      false -> {:error, {:invalid_work_validation_context, :boolean}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_context(_context), do: {:error, {:invalid_work_validation_context, :type}}

  defp execution_mode("live"), do: {:ok, :live}
  defp execution_mode("shadow"), do: {:ok, :shadow}
  defp execution_mode(_mode), do: {:error, {:invalid_work_validation_context, :execution_mode}}

  defp exact_context_fields(context) do
    if Map.keys(context) |> Enum.sort() == @context_fields,
      do: :ok,
      else: {:error, {:invalid_work_validation_context, :fields}}
  end

  defp prepare_artifacts(refs) when is_list(refs) do
    if Enum.uniq(refs) == refs and Enum.all?(refs, &reference?/1),
      do: {:ok, MapSet.new(refs)},
      else: {:error, {:invalid_work_validation_context, :artifact_refs}}
  end

  defp prepare_artifacts(_refs),
    do: {:error, {:invalid_work_validation_context, :artifact_refs}}

  defp prepare_artifact_metadata(values, artifact_refs)
       when is_list(values) and length(values) <= 5 do
    prepared =
      Enum.map(values, fn
        %{"id" => id, "name" => name} = value when map_size(value) == 2 ->
          if reference?(id) and bounded_artifact_name?(name), do: %{id: id, name: name}

        _invalid ->
          nil
      end)

    ids = Enum.map(prepared, &if(&1, do: &1.id))

    if Enum.all?(prepared) and Enum.uniq(ids) == ids and MapSet.new(ids) == artifact_refs,
      do: {:ok, prepared},
      else: {:error, {:invalid_work_validation_context, :artifact_metadata}}
  end

  defp prepare_artifact_metadata(_values, _artifact_refs),
    do: {:error, {:invalid_work_validation_context, :artifact_metadata}}

  defp bounded_artifact_name?(value) when is_binary(value) do
    String.valid?(value) and byte_size(value) in 1..255 and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"]) and
      not Enum.any?(String.to_charlist(value), &(&1 < 32 or &1 == 127))
  end

  defp bounded_artifact_name?(_value), do: false

  defp prepare_open_goals(goals) when is_list(goals) and length(goals) <= 64 do
    Enum.reduce_while(goals, {:ok, []}, fn goal, {:ok, prepared} ->
      case prepare_open_goal(goal) do
        {:ok, goal} -> {:cont, {:ok, [goal | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} ->
        prepared = Enum.reverse(prepared)

        if Enum.uniq_by(prepared, & &1.id) == prepared,
          do: {:ok, prepared},
          else: {:error, {:invalid_work_validation_context, :open_required_goals}}

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_open_goals(_goals),
    do: {:error, {:invalid_work_validation_context, :open_required_goals}}

  defp prepare_open_goal(
         %{
           "id" => id,
           "requested_outcome" => requested_outcome,
           "state" => state
         } = goal
       )
       when map_size(goal) == 3 do
    if reference?(id) and bounded_text?(requested_outcome, 500) and
         state in ~w(ready working waiting blocked) do
      {:ok, %{id: id, requested_outcome: requested_outcome, state: state}}
    else
      {:error, {:invalid_work_validation_context, :open_required_goals}}
    end
  end

  defp prepare_open_goal(_goal),
    do: {:error, {:invalid_work_validation_context, :open_required_goals}}

  defp prepare_records(records) when is_map(records) do
    Enum.reduce_while(records, {:ok, %{}}, fn {ref, record}, {:ok, prepared} ->
      case prepare_record(ref, record) do
        {:ok, record} -> {:cont, {:ok, Map.put(prepared, ref, record)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp prepare_records(_records), do: {:error, {:invalid_work_validation_context, :records}}

  defp prepare_record(ref, %{"continuation" => continuation, "kind" => kind} = record)
       when map_size(record) == 2 do
    with true <- reference?(ref),
         true <- reference?(kind),
         {:ok, continuation} <- prepare_record_continuation(continuation) do
      {:ok, %{continuation: continuation, kind: kind}}
    else
      false -> {:error, {:invalid_work_validation_context, :record}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_record(
         ref,
         %{
           "action" => action,
           "action_kind" => action_kind,
           "continuation" => nil,
           "current_human_inputs" => current_human_inputs,
           "kind" => "platform_action",
           "source_item_ref" => source_item_ref,
           "status" => status,
           "tool" => tool
         } = record
       )
       when map_size(record) == 8 do
    with true <- reference?(ref),
         {:ok, action_kind} <- platform_action_kind(action_kind),
         {:ok, action, source_item_ref} <-
           prepare_platform_action_identity(action_kind, action, source_item_ref),
         {:ok, current_human_inputs} <- prepare_current_human_inputs(current_human_inputs),
         {:ok, status} <- platform_action_status(status),
         true <- tool in ~w(set_slack_reaction post_slack_message set_github_reaction) do
      {:ok,
       %{
         action: action,
         action_kind: action_kind,
         continuation: nil,
         current_human_inputs: current_human_inputs,
         kind: "platform_action",
         source_item_ref: source_item_ref,
         status: status,
         tool: tool
       }}
    else
      _invalid -> {:error, {:invalid_work_validation_context, :record}}
    end
  end

  defp prepare_record(_ref, _record),
    do: {:error, {:invalid_work_validation_context, :record}}

  defp platform_action_kind("message"), do: {:ok, :message}
  defp platform_action_kind("reaction"), do: {:ok, :reaction}
  defp platform_action_kind(_kind), do: {:error, :kind}

  defp prepare_platform_action_identity(:message, nil, nil), do: {:ok, nil, nil}

  defp prepare_platform_action_identity(:reaction, action, source_item_ref)
       when action in ["add", "remove"] do
    if bounded_text?(source_item_ref, 1_024),
      do: {:ok, String.to_existing_atom(action), source_item_ref},
      else: {:error, :source_item_ref}
  end

  defp prepare_platform_action_identity(_kind, _action, _source_item_ref),
    do: {:error, :identity}

  defp prepare_current_human_inputs(inputs) when is_list(inputs) and length(inputs) <= 64 do
    Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, prepared} ->
      case prepare_current_human_input(input) do
        {:ok, input} -> {:cont, {:ok, [input | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} ->
        prepared = Enum.reverse(prepared)

        if Enum.uniq_by(prepared, & &1.input_ref) == prepared,
          do: {:ok, prepared},
          else: {:error, :current_human_inputs}

      {:error, _reason} = error ->
        error
    end
  end

  defp prepare_current_human_inputs(_inputs), do: {:error, :current_human_inputs}

  defp prepare_current_human_input(
         %{"input_ref" => input_ref, "source_item_ref" => source_item_ref} = input
       )
       when map_size(input) == 2 do
    if reference?(input_ref) and
         (is_nil(source_item_ref) or bounded_text?(source_item_ref, 1_024)) do
      {:ok, %{input_ref: input_ref, source_item_ref: source_item_ref}}
    else
      {:error, :current_human_input}
    end
  end

  defp prepare_current_human_input(_input), do: {:error, :current_human_input}

  defp platform_action_status("pending"), do: {:ok, :pending}
  defp platform_action_status("blocked"), do: {:ok, :blocked}
  defp platform_action_status("delivered"), do: {:ok, :delivered}
  defp platform_action_status(_status), do: {:error, :status}

  defp prepare_record_continuation(nil), do: {:ok, nil}

  defp prepare_record_continuation(continuation) when is_map(continuation) do
    case Result.new(:reply, %{"message" => "validation"}, nil, continuation) do
      {:ok, result} -> {:ok, result.continuation}
      {:error, _reason} -> {:error, {:invalid_work_validation_context, :continuation}}
    end
  end

  defp prepare_record_continuation(_continuation),
    do: {:error, {:invalid_work_validation_context, :continuation}}

  defp prepare_workspace(nil), do: {:ok, nil}

  defp prepare_workspace(%{} = workspace) do
    fields =
      ~w(admitted_source_tree base_commit committed_count conflict_count fork_head fork_tree goal_ids repository staged_count unstaged_count untracked_count)

    with true <- Map.keys(workspace) |> Enum.sort() == fields,
         true <-
           Enum.all?(~w(base_commit fork_head fork_tree), &bounded_text?(workspace[&1], 256)),
         true <-
           is_nil(workspace["admitted_source_tree"]) or
             bounded_text?(workspace["admitted_source_tree"], 256),
         true <- bounded_text?(workspace["repository"], 256),
         true <- valid_goal_ids?(workspace["goal_ids"]),
         true <- valid_workspace_counts?(workspace) do
      {:ok, workspace}
    else
      false -> {:error, {:invalid_work_validation_context, :workspace}}
    end
  end

  defp prepare_workspace(_workspace),
    do: {:error, {:invalid_work_validation_context, :workspace}}

  defp valid_goal_ids?(ids) when is_list(ids) and ids != [] and length(ids) <= 64,
    do: Enum.uniq(ids) == ids and Enum.all?(ids, &reference?/1)

  defp valid_goal_ids?(_ids), do: false

  defp valid_workspace_counts?(workspace) do
    Enum.all?(
      ~w(committed_count conflict_count staged_count unstaged_count untracked_count),
      &(is_integer(workspace[&1]) and workspace[&1] >= 0)
    )
  end

  defp continuation_kind(%{"kind" => "wait", "wait_kind" => "input"}), do: :input
  defp continuation_kind(%{"kind" => "wait", "wait_kind" => "event"}), do: :event
  defp continuation_kind(_continuation), do: nil

  defp elapsed?(%{"deadline_at" => nil}, _now), do: false

  defp elapsed?(%{"deadline_at" => deadline_at}, now) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, deadline, 0} -> DateTime.compare(deadline, now) != :gt
      _invalid -> true
    end
  end

  defp reject(violation), do: {:reject, [violation]}

  defp final_violation(:type),
    do: "Return one JSON object matching the attached output schema."

  defp final_violation(:fields),
    do:
      "The top-level object must contain exactly decision_reason, delivery, message, and outcome; remove unknown fields and add missing fields."

  defp final_violation(:delivery),
    do: "delivery must be exactly reply or none."

  defp final_violation(:message),
    do:
      "For delivery reply, message must be nonblank text with no NUL character and at most 20,000 Unicode characters."

  defp final_violation(:decision_reason),
    do:
      "For delivery none, decision_reason must be nonblank text with no NUL character and at most 240 Unicode characters."

  defp final_violation(:delivery_shape),
    do:
      "For delivery reply, provide message and set decision_reason to null; for delivery none, set message to null and provide decision_reason."

  defp final_violation(:outcome),
    do:
      "outcome must contain exactly artifact_refs, record_refs, and state using the attached output schema."

  defp final_violation(:state),
    do: "outcome.state must be complete, waiting_for_input, or waiting_for_event."

  defp final_violation(:record_refs),
    do:
      "outcome.record_refs must contain at most 64 unique host-issued references using only letters, numbers, underscore, dot, colon, or hyphen, each at most 256 characters."

  defp final_violation(:artifact_refs),
    do:
      "outcome.artifact_refs must contain at most 5 unique host-issued references using only letters, numbers, underscore, dot, colon, or hyphen, each at most 256 characters."

  defp final_violation(:state_requires_visible_reply),
    do:
      "An input-waiting outcome requires delivery reply so the user can answer. Event waiting may use delivery none with its durable wait record."

  defp final_violation(:waiting_state_requires_record),
    do:
      "A waiting outcome must reference the durable request_input, wait_for, or record_emisar_approval record that will resume it."

  defp reference?(value),
    do: is_binary(value) and String.valid?(value) and Regex.match?(@reference_regex, value)

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end
end
