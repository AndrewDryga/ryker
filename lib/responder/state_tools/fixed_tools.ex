defmodule Responder.StateTools.FixedTools do
  @moduledoc false

  alias Responder.CanonicalJSON
  alias Responder.Delivery.{PlatformActionCustody, Presentation}
  alias Responder.Repo
  alias Responder.Slack.Mentions
  alias Responder.State.{Automations, Memories, Record, Records}
  alias Responder.Work.{Custody, Final, FinalPreflight, Validator}

  @contract_version "responder-state:v1"
  @confirmation_tools ~w(propose_automation propose_memory request_task)
  @maximum_automation_proposals 4
  @names ~w(
    get_work_state
    cite_source
    request_input
    wait_for
    list_automations
    get_automation
    propose_automation
    request_task
    search_memory
    propose_memory
    record_feedback
    validate_final
  )

  @spec names() :: [String.t()]
  def names, do: @names

  @spec known?(term()) :: boolean()
  def known?(name), do: name in @names

  @spec list(keyword() | map()) :: [map()]
  def list(options \\ %{}) do
    capabilities = capabilities(options)

    [
      get_work_state_tool(),
      cite_source_tool(),
      request_input_tool(),
      if(:event_waits in capabilities, do: wait_for_tool()),
      list_automations_tool(),
      get_automation_tool(),
      propose_automation_tool(capabilities),
      request_task_tool(),
      search_memory_tool(),
      propose_memory_tool(),
      record_feedback_tool(),
      validate_final_tool()
    ]
    |> Enum.reject(fn
      nil ->
        true

      tool ->
        tool["name"] in @confirmation_tools and not confirmation_surface?(options)
    end)
  end

  @spec call(String.t(), map(), keyword() | map()) :: {:ok, map()} | {:error, String.t()}
  def call(name, arguments, options) when name in @names and is_map(arguments) do
    with :ok <- capability_available(name, arguments, options),
         {:ok, binding} <- tool_binding(options),
         :ok <- exact_schema(name, arguments, options) do
      binding = Map.put(binding, :capabilities, capabilities(options))

      case dispatch(name, arguments, binding) do
        {:ok, _result} = success -> success
        {:error, reason} -> {:error, error_code(reason)}
      end
    else
      {:error, reason} -> {:error, error_code(reason)}
    end
  end

  def call(_name, _arguments, _options), do: {:error, "unknown_tool"}

  defp dispatch("get_work_state", arguments, binding) do
    records = Records.model_records(binding.episode.id)
    platform_actions = PlatformActionCustody.model_actions(binding.episode.id)
    limit = Map.get(arguments, "limit", 100)

    {:ok,
     %{
       "cursor" => "episode:#{binding.episode.id}:v#{binding.episode.semantic_version}",
       "episode" => %{
         "episode_ref" => binding.episode.key,
         "owner" => Atom.to_string(binding.episode.owner_kind),
         "state" => Atom.to_string(binding.episode.state)
       },
       "platform_actions" => platform_actions,
       "records" => Enum.take(records, limit)
     }}
  end

  defp dispatch("cite_source", arguments, binding) do
    relation = if arguments["relation"] == "context", do: nil, else: arguments["relation"]

    payload = %{
      "claim" => arguments["subject"],
      "claim_id" => subject_ref("citation", arguments),
      "confidence" => nil,
      "dimensions" => %{},
      "freshness" => nil,
      "health_effect" => nil,
      "observation" => arguments["observation"],
      "observed_at" => nil,
      "relation" => relation,
      "scope_note" => nil,
      "source_id" => arguments["source_ref"],
      "source_name" => arguments["source_ref"],
      "source_type" => "other",
      "supersedes" => arguments["supersedes"],
      "target" => arguments["subject"]
    }

    create_record(binding, "cite_source", arguments, "evidence", payload, "citation")
  end

  defp dispatch("request_input", arguments, binding) do
    questions = arguments["questions"]

    payload = %{
      "choices" => if(length(questions) == 1, do: hd(questions)["choices"], else: []),
      "question" => question_text(questions, arguments["context"])
    }

    create_record(binding, "request_input", arguments, "input_request", payload)
  end

  defp dispatch("wait_for", arguments, binding) do
    trigger = Map.put(arguments["trigger"], "on_timeout", arguments["on_timeout"])

    payload = %{
      "deadline_at" => arguments["deadline"],
      "event_matcher" => trigger,
      "kind" => arguments["trigger"]["type"],
      "verification" => arguments["verification"]
    }

    create_record(binding, "wait_for", arguments, "event_wait", payload)
  end

  defp dispatch("list_automations", arguments, binding) do
    with :ok <- automation_list_channel(arguments["channel_ref"], binding) do
      automations =
        binding.episode
        |> Automations.list_for_episode()
        |> filter_automations(arguments)
        |> Enum.take(Map.get(arguments, "limit", 50))

      {:ok, %{"automations" => automations, "cursor" => nil}}
    end
  end

  defp dispatch("get_automation", arguments, binding) do
    case Automations.fetch_for_episode(binding.episode, arguments["automation_id"]) do
      {:ok, automation} ->
        {:ok, %{"automation" => Automations.detail(automation, arguments["run_limit"])}}

      :error ->
        {:error, :not_found}
    end
  end

  defp dispatch("propose_automation", arguments, binding) do
    proposals = arguments["proposals"]

    Repo.transaction(fn ->
      Enum.with_index(proposals)
      |> Enum.reduce_while([], &prepare_automation_record(&1, &2, binding))
      |> Enum.reverse()
    end)
    |> case do
      {:ok, records} -> {:ok, %{"proposals" => records}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dispatch("request_task", arguments, binding) do
    kind = Map.get(arguments, "kind", "engineering")
    arguments = Map.put(arguments, "kind", kind)

    with :ok <- task_repository(kind, arguments["repository"]),
         {:ok, instruction_ref} <- task_instruction_ref(arguments, binding) do
      payload = %{
        "authority_limits" => arguments["authority_limits"],
        "instruction_ref" => instruction_ref,
        "kind" => kind,
        "prompt" => task_prompt(arguments, instruction_ref),
        "repository" => arguments["repository"],
        "source_refs" => arguments["source_refs"],
        "success_checks" => arguments["success_checks"],
        "title" => arguments["title"]
      }

      create_record(binding, "request_task", arguments, "task_offer", payload)
    end
  end

  defp dispatch("search_memory", arguments, binding) do
    context = %{
      conversation_ref: binding.episode.destination_conversation_ref,
      repository: binding.session.repository_ref,
      workspace_ref:
        workspace_ref(
          binding.episode.destination_transport,
          binding.episode.destination_conversation_ref
        )
    }

    query = String.downcase(arguments["query"])

    memories =
      context
      |> Memories.recall(arguments["limit"])
      |> Enum.filter(fn memory ->
        memory |> CanonicalJSON.encode!() |> String.downcase() |> String.contains?(query)
      end)

    {:ok, %{"cursor" => nil, "memories" => memories}}
  end

  defp dispatch("propose_memory", arguments, binding) do
    case arguments["kind"] do
      "guidance" ->
        payload = %{
          "expires_in" => expiry(arguments["expires_at"]),
          "repository" => memory_repository(arguments, binding),
          "scope" => memory_scope(arguments["scope"]),
          "subject" => arguments["subject"],
          "summary" => String.slice(arguments["value"], 0, 500),
          "text" => arguments["value"],
          "visibility" => memory_visibility(arguments["scope"])
        }

        create_record(
          binding,
          "propose_memory",
          arguments,
          "guidance_offer",
          payload,
          "memory_offer"
        )

      "fact" ->
        payload = %{
          "expires_in" => expiry(arguments["expires_at"]),
          "kind" => "entity_relationship",
          "repository" => memory_repository(arguments, binding),
          "scope" => fact_scope(arguments["scope"]),
          "subject" => arguments["subject"],
          "value" => arguments["value"],
          "visibility" => fact_visibility(arguments["scope"])
        }

        create_record(binding, "propose_memory", arguments, "memory_offer", payload)
    end
  end

  defp dispatch("record_feedback", arguments, binding) do
    payload = %{
      "next_due_at" => nil,
      "phase" => "feedback:#{arguments["category"]}:#{arguments["sentiment"]}",
      "summary" => feedback_summary(arguments)
    }

    create_record(binding, "record_feedback", arguments, "progress", payload, "feedback")
  end

  defp dispatch("validate_final", %{"candidate" => candidate}, binding) do
    candidate_json = CanonicalJSON.encode!(candidate)
    candidate_sha256 = FinalPreflight.candidate_sha256(candidate)
    artifact_refs = get_in(candidate, ["outcome", "artifact_refs"]) || []
    validation_context = validation_context(binding, artifact_refs)

    ledger_sha256 =
      FinalPreflight.ledger_sha256(
        binding.episode.id,
        binding.episode.semantic_version,
        artifact_refs,
        binding.turn.id
      )

    # Coop derives output artifact identities while it is completing the
    # provider turn. Those bytes cannot exist in Responder before this
    # in-turn preflight. FinalPreflight excludes only those late-issued refs;
    # the terminal Work validator requires every ref in Coop's exact manifest,
    # then fetches and digest-checks the bytes before accepting the result or
    # creating delivery custody.
    with {:accept, %{final: final}} <-
           Validator.validate(candidate_json, validation_context, DateTime.utc_now()),
         :ok <- Presentation.validate(binding.episode, binding.turn.id, final),
         {:ok, _turn} <-
           Custody.record_final_preflight(
             binding.episode.id,
             binding.turn.turn_ref,
             binding.turn.lease_ref,
             candidate_sha256,
             ledger_sha256,
             binding.episode.semantic_version
           ) do
      {:ok,
       %{
         "accepted" => true,
         "candidate" => Final.document(final),
         "candidate_sha256" => candidate_sha256,
         "ledger_version" => binding.episode.semantic_version
       }}
    else
      {:reject, violations} ->
        {:ok, %{"accepted" => false, "violations" => violations}}

      {:error, {:invalid_delivery_presentation, reason}} ->
        {:ok,
         %{
           "accepted" => false,
           "violations" => [presentation_violation(reason)]
         }}

      {:error, reason} ->
        {:error, error_code(reason)}
    end
  end

  # Feedback may name the one open task offer it is refining. Keep the original
  # trusted instruction as the task identity so the new record supersedes the
  # pending proposal instead of creating a second task. Cross-episode,
  # cross-repository, terminal, and non-task refs never grant this authority.
  defp task_instruction_ref(
         %{
           "instruction_ref" => "record:task_offer:" <> _suffix = record_ref,
           "kind" => requested_kind,
           "repository" => requested_repository
         },
         binding
       ) do
    case Records.fetch_for_episode(binding.episode.id, [record_ref]) do
      {:ok,
       [
         %Record{
           kind: "task_offer",
           payload: %{
             "instruction_ref" => instruction_ref,
             "kind" => kind,
             "repository" => repository
           },
           status: :open
         }
       ]}
      when kind == requested_kind and repository == requested_repository and
             is_binary(instruction_ref) and
             byte_size(instruction_ref) > 0 ->
        {:ok, instruction_ref}

      _invalid ->
        {:error, {:invalid_state_record, :instruction_ref}}
    end
  end

  defp task_instruction_ref(%{"instruction_ref" => instruction_ref}, _binding),
    do: {:ok, instruction_ref}

  defp task_repository("engineering", value) when is_binary(value), do: :ok
  defp task_repository("incident", value) when is_nil(value) or is_binary(value), do: :ok
  defp task_repository(_kind, _repository), do: {:error, {:invalid_state_record, :repository}}

  defp prepare_automation_record({proposal, index}, records, binding) do
    case automation_record(binding, proposal, index) do
      {:ok, record} -> {:cont, [record | records]}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp presentation_violation(reason) do
    "The final response cannot be rendered safely for this destination: #{inspect(reason, limit: 8, printable_limit: 256)}"
  end

  defp automation_record(
         binding,
         %{"action" => "create", "trigger" => %{"type" => "source_event"} = trigger} = proposal,
         index
       ) do
    with :ok <- automation_capability("source_event", binding),
         {:ok, context_channel} <- automation_channel(proposal["context_channel"], binding),
         {:ok, delivery_channel} <- automation_channel(proposal["delivery_channel"], binding),
         :ok <- source_event_hold(proposal["hold"]) do
      payload = %{
        "catch_up" => proposal["catch_up"],
        "context_channel" => context_channel,
        "delivery_channel" => delivery_channel,
        "expires_at" => proposal["expires_at"],
        "filter" => trigger["filter"] || %{},
        "hold" => nil,
        "repository" => proposal["repository"],
        "source_kind" => trigger["source_kind"],
        "task" => proposal["prompt"],
        "title" => proposal["title"]
      }

      create_record(
        binding,
        "propose_automation:#{index}",
        proposal,
        "standing_assignment_offer",
        payload,
        "automation_offer"
      )
    end
  end

  defp automation_record(binding, %{"action" => "create"} = proposal, index) do
    with :ok <- automation_capability("time", binding) do
      recurrence = automation_recurrence(proposal["trigger"])

      payload = %{
        "authority" => if(proposal["repository"], do: "repository_write", else: "read_only"),
        "catch_up" => proposal["catch_up"],
        "expires_at" => proposal["expires_at"],
        "recurrence" => recurrence,
        "repository" => proposal["repository"],
        "task" => proposal["prompt"],
        "timezone" => proposal["trigger"]["timezone"] || "Etc/UTC",
        "title" => proposal["title"]
      }

      create_record(
        binding,
        "propose_automation:#{index}",
        proposal,
        "schedule_offer",
        payload,
        "automation_offer"
      )
    end
  end

  defp automation_record(binding, %{"action" => action} = proposal, index)
       when action in ~w(update pause resume delete) do
    with {:ok, payload} <- Automations.prepare_change(binding.episode, proposal),
         :ok <- automation_capability(payload["automation_kind"], binding) do
      create_record(
        binding,
        "propose_automation:#{index}",
        proposal,
        "automation_change_offer",
        payload,
        "automation_offer"
      )
    end
  end

  defp automation_record(_binding, _proposal, _index), do: {:error, :not_configured}

  defp automation_capability("source_event", _binding), do: :ok

  defp automation_capability("time", binding) do
    if :schedules in binding.capabilities, do: :ok, else: {:error, :not_configured}
  end

  defp automation_channel(nil, binding),
    do: {:ok, binding.episode.destination_conversation_ref}

  defp automation_channel(channel, binding)
       when channel == binding.episode.destination_conversation_ref,
       do: {:ok, channel}

  defp automation_channel(_channel, _binding), do: {:error, :unauthorized}

  defp automation_list_channel(nil, _binding), do: :ok

  defp automation_list_channel(channel, binding)
       when channel == binding.episode.destination_conversation_ref,
       do: :ok

  defp automation_list_channel(_channel, _binding), do: {:error, :unauthorized}

  defp source_event_hold(nil), do: :ok
  defp source_event_hold(_hold), do: {:error, :not_configured}

  defp create_record(binding, tool, arguments, kind, payload, public_kind \\ nil) do
    operation_id = operation_id(binding, tool, arguments)

    case Records.create(binding.state_token, operation_id, kind, payload) do
      {:ok, record} ->
        {:ok,
         %{
           "continuation" => record.continuation,
           "kind" => public_kind || record.kind,
           "record_ref" => record.ref
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validation_context(binding, artifact_refs) do
    %{
      "artifact_delivery_supported" =>
        binding.episode.destination_transport in ["github", "slack"],
      "artifact_metadata" => Enum.map(artifact_refs, &%{"id" => &1, "name" => &1}),
      "artifact_refs" => artifact_refs,
      "execution_mode" => Atom.to_string(binding.episode.execution_mode),
      "open_required_goals" => [],
      "records" => validation_records(binding.episode.id, binding.turn.id),
      "slack_mentions" => Mentions.authority(binding.episode),
      "visible_reply_required" => true,
      "workspace" => nil
    }
  end

  defp validation_records(episode_id, turn_id) do
    Map.merge(
      Records.validation_records(episode_id),
      PlatformActionCustody.validation_records(episode_id, turn_id)
    )
  end

  defp tool_binding(options) when is_list(options), do: options |> Map.new() |> tool_binding()

  defp tool_binding(%{
         binding: %{episode: episode, session: session, state_token: token, turn: turn}
       })
       when is_binary(token),
       do: {:ok, %{episode: episode, session: session, state_token: token, turn: turn}}

  defp tool_binding(%{"binding" => binding}), do: tool_binding(%{binding: binding})
  defp tool_binding(_options), do: {:error, :unauthorized}

  defp operation_id(binding, tool, arguments) do
    digest(
      CanonicalJSON.encode!(%{
        "contract_version" => @contract_version,
        "episode_id" => binding.episode.id,
        "host_slot" => host_slot(tool, arguments),
        "tool" => tool,
        "turn_id" => binding.turn.id
      })
    )
    |> then(&("host:" <> &1))
  end

  defp host_slot("request_input", _arguments), do: "question-set"
  defp host_slot("wait_for", _arguments), do: "pending-wait"

  defp host_slot("request_task", arguments),
    do: [
      Map.get(arguments, "kind", "engineering"),
      arguments["repository"],
      arguments["instruction_ref"]
    ]

  defp host_slot("cite_source", arguments),
    do: [arguments["source_ref"], arguments["subject"], arguments["relation"]]

  defp host_slot("propose_memory", arguments),
    do: [arguments["scope"], arguments["kind"], arguments["subject"]]

  defp host_slot("record_feedback", arguments),
    do: [arguments["target_message_ref"], arguments["category"]]

  defp host_slot("validate_final", arguments), do: digest(CanonicalJSON.encode!(arguments))
  defp host_slot("propose_automation:" <> index, _arguments), do: index
  defp host_slot(_tool, arguments), do: digest(CanonicalJSON.encode!(arguments))

  defp exact_schema(name, arguments, options) do
    case Enum.find(list(options), &(&1["name"] == name)) do
      %{"inputSchema" => schema} ->
        if valid_schema_value?(schema, arguments), do: :ok, else: {:error, :invalid_arguments}

      nil ->
        {:error, :not_configured}
    end
  end

  defp valid_schema_value?(%{"anyOf" => schemas}, value),
    do: Enum.any?(schemas, &valid_schema_value?(&1, value))

  defp valid_schema_value?(%{"oneOf" => schemas} = schema, value) do
    base = Map.drop(schema, ["oneOf"])

    base_valid =
      map_size(base) == 0 or Map.keys(base) == ["additionalProperties"] or
        valid_schema_value?(base, value)

    base_valid and Enum.count(schemas, &valid_schema_value?(&1, value)) == 1
  end

  defp valid_schema_value?(%{"const" => expected} = schema, value),
    do: value == expected and valid_schema_value?(Map.drop(schema, ["const"]), value)

  defp valid_schema_value?(%{"enum" => values} = schema, value),
    do: value in values and valid_schema_value?(Map.drop(schema, ["enum"]), value)

  defp valid_schema_value?(%{"properties" => _properties} = schema, value)
       when is_map(value) and not is_map_key(schema, "type"),
       do: valid_schema_value?(Map.put(schema, "type", "object"), value)

  defp valid_schema_value?(%{"type" => "object"} = schema, value) when is_map(value) do
    properties = Map.get(schema, "properties", %{})
    required = Map.get(schema, "required", [])
    keys = Map.keys(value)

    Enum.all?(required, &Map.has_key?(value, &1)) and
      (Map.get(schema, "additionalProperties", true) != false or
         Enum.all?(keys, &Map.has_key?(properties, &1))) and
      Enum.all?(value, fn {key, child} ->
        case Map.fetch(properties, key) do
          {:ok, child_schema} -> valid_schema_value?(child_schema, child)
          :error -> Map.get(schema, "additionalProperties", true) != false
        end
      end)
  end

  defp valid_schema_value?(%{"type" => "array"} = schema, value) when is_list(value) do
    length = length(value)

    length >= Map.get(schema, "minItems", 0) and
      length <= Map.get(schema, "maxItems", length) and
      (Map.get(schema, "uniqueItems", false) == false or Enum.uniq(value) == value) and
      Enum.all?(value, &valid_schema_value?(schema["items"], &1))
  end

  defp valid_schema_value?(%{"type" => "string"} = schema, value) when is_binary(value) do
    length = String.length(value)

    String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      length >= Map.get(schema, "minLength", 0) and
      length <= Map.get(schema, "maxLength", length) and
      valid_pattern?(value, schema["pattern"]) and valid_format?(value, schema["format"])
  end

  defp valid_schema_value?(%{"type" => "integer"} = schema, value) when is_integer(value),
    do:
      value >= Map.get(schema, "minimum", value) and
        value <= Map.get(schema, "maximum", value)

  defp valid_schema_value?(%{"type" => "boolean"}, value), do: is_boolean(value)
  defp valid_schema_value?(%{"type" => "null"}, value), do: is_nil(value)
  defp valid_schema_value?(schema, _value) when map_size(schema) == 0, do: true
  defp valid_schema_value?(_schema, _value), do: false

  defp valid_pattern?(_value, nil), do: true

  defp valid_pattern?(value, pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _reason} -> false
    end
  end

  defp valid_format?(_value, nil), do: true

  defp valid_format?(value, "date-time") do
    match?({:ok, %DateTime{}, 0}, DateTime.from_iso8601(value))
  end

  defp valid_format?(_value, _format), do: false

  defp filter_automations(automations, arguments) do
    automations
    |> Enum.filter(fn automation ->
      enabled = arguments["enabled"]
      enabled_match = is_nil(enabled) or enabled == (automation["status"] == "active")
      trigger_match = trigger_matches?(automation, arguments["trigger_type"])
      query_match = query_matches?(automation, arguments["query"])
      enabled_match and trigger_match and query_match
    end)
  end

  defp trigger_matches?(_automation, nil), do: true

  defp trigger_matches?(automation, "time"),
    do: automation["trigger"]["type"] == "time"

  defp trigger_matches?(automation, "source_event"),
    do: automation["trigger"]["type"] == "source_event"

  defp query_matches?(_automation, nil), do: true

  defp query_matches?(automation, query) do
    String.contains?(String.downcase(automation["title"]), String.downcase(query))
  end

  defp automation_recurrence(%{"type" => "time", "recurrence" => "once", "at" => at}),
    do: %{"at" => at, "kind" => "once"}

  defp automation_recurrence(%{"type" => "time", "recurrence" => "daily", "time" => time}),
    do: %{"kind" => "daily", "time" => time}

  defp automation_recurrence(%{
         "type" => "time",
         "recurrence" => "weekly",
         "time" => time,
         "weekday" => weekday
       }),
       do: %{"kind" => "weekly", "time" => time, "weekday" => weekday}

  defp automation_recurrence(%{
         "type" => "time",
         "recurrence" => "monthly",
         "day" => day,
         "time" => time
       }),
       do: %{"day" => day, "kind" => "monthly", "time" => time}

  defp automation_recurrence(
         %{
           "type" => "time",
           "recurrence" => "interval",
           "every_seconds" => every_seconds
         } = trigger
       ),
       do: %{
         "every_seconds" => every_seconds,
         "kind" => "interval",
         "starts_at" => trigger["starts_at"]
       }

  defp automation_recurrence(trigger), do: %{"kind" => "source_event", "trigger" => trigger}

  defp question_text(questions, context) do
    body =
      questions
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {question, index} -> "#{index}. #{question["text"]}" end)

    if is_binary(context), do: context <> "\n\n" <> body, else: body
  end

  defp task_prompt(arguments, instruction_ref) do
    [
      arguments["prompt"],
      "Success checks: " <> Enum.join(arguments["success_checks"], "; "),
      "Authority limits: " <> Enum.join(arguments["authority_limits"], "; "),
      "Instruction: " <> instruction_ref,
      "Sources: " <> Enum.join(arguments["source_refs"], ", ")
    ]
    |> Enum.join("\n\n")
  end

  defp feedback_summary(arguments) do
    [arguments["summary"], arguments["details"], arguments["response_question"]]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp subject_ref(prefix, arguments),
    do: prefix <> ":" <> binary_part(digest(CanonicalJSON.encode!(arguments)), 0, 32)

  defp memory_repository(%{"scope" => "repository"}, binding), do: binding.session.repository_ref
  defp memory_repository(_arguments, _binding), do: nil

  defp memory_scope("mine"), do: "operator"
  defp memory_scope("current_channel"), do: "conversation"
  defp memory_scope(scope), do: scope

  defp fact_scope("mine"), do: "conversation"
  defp fact_scope("current_channel"), do: "conversation"
  defp fact_scope(scope), do: scope

  defp memory_visibility("mine"), do: "private"
  defp memory_visibility("current_channel"), do: "conversation"
  defp memory_visibility(_scope), do: "workspace"

  defp fact_visibility("current_channel"), do: "conversation"
  defp fact_visibility(_scope), do: "workspace"

  defp expiry(nil), do: "90d"

  defp expiry(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, 0} -> expiry_bucket(expires_at)
      _invalid -> "90d"
    end
  end

  defp expiry_bucket(expires_at) do
    days = max(DateTime.diff(expires_at, DateTime.utc_now(), :day), 0)

    cond do
      days <= 7 -> "7d"
      days <= 30 -> "30d"
      days <= 90 -> "90d"
      true -> "365d"
    end
  end

  defp workspace_ref("slack", "slack:" <> workspace_and_rest),
    do: "slack:" <> (workspace_and_rest |> String.split(":", parts: 2) |> hd())

  defp workspace_ref("github", "github:" <> binding_and_rest),
    do: "github:" <> (binding_and_rest |> String.split(":", parts: 2) |> hd())

  defp workspace_ref(transport, conversation_ref), do: transport <> ":" <> conversation_ref

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp error_code(:unauthorized), do: "unauthorized"
  defp error_code(:invalid_arguments), do: "invalid_arguments"
  defp error_code(:not_configured), do: "not_configured"
  defp error_code(:not_found), do: "not_found"
  defp error_code(:deadline_elapsed), do: "deadline_elapsed"
  defp error_code(:unknown_tool), do: "unknown_tool"
  defp error_code(:automation_change_offer_invalid), do: "invalid_arguments"
  defp error_code(:automation_not_future), do: "invalid_arguments"
  defp error_code(:automation_status_conflict), do: "operation_conflict"
  defp error_code({:automation_revision_conflict, _revision}), do: "operation_conflict"
  defp error_code(:state_record_unauthorized), do: "unauthorized"
  defp error_code(:state_record_confirmation_unsupported), do: "confirmation_unsupported"
  defp error_code(:state_record_shadow_forbidden), do: "unauthorized"
  defp error_code(:state_record_operation_conflict), do: "operation_conflict"
  defp error_code({:invalid_schedule, _field}), do: "invalid_arguments"
  defp error_code({:invalid_state_record, _field}), do: "invalid_arguments"
  defp error_code(_reason), do: "temporarily_unavailable"

  defp get_work_state_tool do
    tool(
      "get_work_state",
      "Read bounded durable state for this exact episode.",
      %{
        "history" => enum(~w(current include_linked)),
        "limit" => integer(1, 100),
        "since" => nullable(reference(256)),
        "types" =>
          array(
            enum(~w(source_revision citation input wait proposal action artifact outcome)),
            1,
            8
          )
      },
      ~w(history limit types)
    )
  end

  defp cite_source_tool do
    tool(
      "cite_source",
      "Preserve one source-backed observation for this episode.",
      %{
        "observation" => text(4_000),
        "relation" => enum(~w(supports contradicts context)),
        "source_ref" => reference(256),
        "subject" => text(120),
        "supersedes" => array(reference(256), 0, 10)
      },
      ~w(observation relation source_ref subject supersedes)
    )
  end

  defp request_input_tool do
    question =
      object(
        %{
          "choices" => array(text(240), 0, 5),
          "text" => text(2_000)
        },
        ~w(choices text)
      )

    tool(
      "request_input",
      "Create one durable question card for a material human decision.",
      %{
        "context" => nullable(text(2_000)),
        "questions" => array(question, 1, 3)
      },
      ~w(questions)
    )
  end

  defp wait_for_tool do
    trigger = %{
      "additionalProperties" => false,
      "oneOf" => [
        object(%{"delay" => text(64), "type" => const("after")}, ~w(delay type)),
        object(%{"at" => timestamp(), "type" => const("at")}, ~w(at type)),
        object(
          %{
            "match" => %{"additionalProperties" => true, "type" => "object"},
            "source_kind" => nullable(reference(120)),
            "type" => const("source_event")
          },
          ~w(match type)
        )
      ]
    }

    tool("wait_for", "Create one durable event wait with a deadline and fallback.", %{
      "deadline" => timestamp(),
      "on_timeout" => text(2_000),
      "trigger" => trigger,
      "verification" => text(2_000)
    })
  end

  defp list_automations_tool do
    tool(
      "list_automations",
      "Find visible durable automations before reading or changing one.",
      %{
        "channel_ref" => nullable(reference(256)),
        "cursor" => nullable(reference(256)),
        "enabled" => nullable(%{"type" => "boolean"}),
        "limit" => integer(1, 50),
        "query" => nullable(text(500)),
        "relationship" => enum(~w(context delivery either)),
        "trigger_type" => nullable(enum(~w(time source_event)))
      },
      ~w(limit relationship)
    )
  end

  defp get_automation_tool do
    tool("get_automation", "Read one exact visible automation and recent run state.", %{
      "automation_id" => reference(256),
      "run_limit" => integer(1, 20)
    })
  end

  defp propose_automation_tool(capabilities) do
    create =
      object(
        %{
          "action" => const("create"),
          "automation_id" => nullable(reference(256)),
          "catch_up" => enum(~w(latest skip)),
          "context_channel" => nullable(reference(256)),
          "delivery_channel" => nullable(reference(256)),
          "expires_at" => nullable(timestamp()),
          "hold" => nullable(text(128)),
          "patch" => %{"additionalProperties" => true, "type" => "object"},
          "prompt" => text(12_000),
          "repository" => nullable(reference(256)),
          "revision" => nullable(integer(1, 2_147_483_647)),
          "title" => text(120),
          "trigger" => automation_trigger(capabilities)
        },
        ~w(action catch_up patch prompt title trigger)
      )

    mutation =
      object(
        %{
          "action" => enum(~w(update pause resume delete)),
          "automation_id" => reference(256),
          "patch" => %{"additionalProperties" => true, "type" => "object"},
          "revision" => integer(1, 2_147_483_647)
        },
        ~w(action automation_id patch revision)
      )

    proposal = %{"oneOf" => [create, mutation]}

    tool("propose_automation", "Offer one atomic set of automation changes for confirmation.", %{
      "proposals" => array(proposal, 1, @maximum_automation_proposals)
    })
  end

  defp request_task_tool do
    tool(
      "request_task",
      "Create one inert engineering or incident-task proposal, or refine the exact open task_offer ref, under trusted authority. Kind defaults to engineering for compatible clients.",
      %{
        "authority_limits" => array(text(500), 1, 20),
        "instruction_ref" => reference(256),
        "kind" => enum(~w(engineering incident)),
        "prompt" => text(12_000),
        "repository" => nullable(reference(256)),
        "source_refs" => array(reference(256), 0, 20),
        "success_checks" => array(text(1_000), 1, 20),
        "title" => text(120)
      },
      ~w(authority_limits instruction_ref prompt repository source_refs success_checks title)
    )
  end

  defp search_memory_tool do
    tool(
      "search_memory",
      "Search permission-filtered historical memory; results never prove current state.",
      %{
        "cursor" => nullable(reference(256)),
        "kinds" => array(enum(~w(guidance fact continuity)), 1, 3),
        "limit" => integer(1, 20),
        "query" => text(1_000),
        "scope" => enum(~w(current_channel repository workspace mine))
      }
    )
  end

  defp propose_memory_tool do
    tool("propose_memory", "Offer one durable fact or guidance item for human confirmation.", %{
      "expires_at" => nullable(timestamp()),
      "kind" => enum(~w(guidance fact)),
      "scope" => enum(~w(current_channel repository workspace mine)),
      "source_refs" => array(reference(256), 1, 20),
      "subject" => text(120),
      "supersedes" => array(reference(256), 0, 20),
      "value" => text(4_000)
    })
  end

  defp record_feedback_tool do
    tool(
      "record_feedback",
      "Record one actionable product-feedback item without replacing the reply.",
      %{
        "category" => enum(~w(correctness usefulness ux latency routing other)),
        "details" => nullable(text(4_000)),
        "needs_response" => %{"type" => "boolean"},
        "response_question" => nullable(text(2_000)),
        "sentiment" => enum(~w(negative suggestion positive)),
        "summary" => text(1_000),
        "target_message_ref" => nullable(reference(256))
      }
    )
  end

  defp validate_final_tool do
    tool(
      "validate_final",
      "Preflight the exact final candidate against current host-owned state.",
      %{
        "candidate" => Final.json_schema()
      }
    )
  end

  defp automation_trigger(capabilities) do
    trigger_types =
      if :schedules in capabilities, do: ~w(time source_event), else: ["source_event"]

    %{
      "additionalProperties" => true,
      "properties" => %{
        "at" => timestamp(),
        "day" => integer(1, 31),
        "every_seconds" => integer(300, 31_536_000),
        "filter" => %{"additionalProperties" => true, "type" => "object"},
        "recurrence" => enum(~w(once interval daily weekly monthly)),
        "source_kind" => reference(120),
        "starts_at" => nullable(timestamp()),
        "time" => text(32),
        "timezone" => text(128),
        "type" => enum(trigger_types),
        "weekday" => enum(~w(monday tuesday wednesday thursday friday saturday sunday))
      },
      "required" => ["type"],
      "type" => "object"
    }
  end

  defp tool(name, description, properties, required \\ nil) do
    %{
      "description" => description,
      "inputSchema" => object(properties, required || Map.keys(properties)),
      "name" => name
    }
  end

  defp object(properties, required) do
    %{
      "additionalProperties" => false,
      "properties" => properties,
      "required" => Enum.sort(required),
      "type" => "object"
    }
  end

  defp array(items, minimum, maximum) do
    %{
      "items" => items,
      "maxItems" => maximum,
      "minItems" => minimum,
      "type" => "array",
      "uniqueItems" => true
    }
  end

  defp enum(values), do: %{"enum" => values, "type" => "string"}
  defp const(value), do: %{"const" => value, "type" => "string"}

  defp integer(minimum, maximum),
    do: %{"maximum" => maximum, "minimum" => minimum, "type" => "integer"}

  defp nullable(schema), do: %{"anyOf" => [schema, %{"type" => "null"}]}

  defp reference(maximum),
    do: %{
      "maxLength" => maximum,
      "minLength" => 1,
      "pattern" => "^[A-Za-z0-9_.:-]+$",
      "type" => "string"
    }

  defp text(maximum), do: %{"maxLength" => maximum, "minLength" => 1, "type" => "string"}
  defp timestamp, do: %{"format" => "date-time", "type" => "string"}

  defp capability_available(name, _arguments, options) when name in @confirmation_tools do
    if confirmation_surface?(options), do: :ok, else: {:error, :unknown_tool}
  end

  defp capability_available("wait_for", _arguments, options) do
    if :event_waits in capabilities(options), do: :ok, else: {:error, :not_configured}
  end

  defp capability_available(_name, _arguments, _options), do: :ok

  defp confirmation_surface?(options) when is_list(options) do
    if Keyword.keyword?(options), do: confirmation_surface?(Map.new(options)), else: true
  end

  defp confirmation_surface?(%{
         binding: %{
           episode: %{destination_transport: transport, execution_mode: execution_mode}
         }
       }),
       do: transport in ["slack", "control_plane", "github"] and execution_mode == :live

  defp confirmation_surface?(%{
         "binding" => %{
           "episode" => %{
             "destination_transport" => transport,
             "execution_mode" => execution_mode
           }
         }
       }),
       do: transport in ["slack", "control_plane", "github"] and execution_mode == "live"

  defp confirmation_surface?(_options), do: true

  defp capabilities(options) when is_list(options) do
    if Keyword.keyword?(options),
      do: Keyword.get(options, :capabilities, [:event_waits, :publication, :schedules]),
      else: []
  end

  defp capabilities(%{} = options),
    do: Map.get(options, :capabilities, [:event_waits, :publication, :schedules])

  defp capabilities(_options), do: []
end
