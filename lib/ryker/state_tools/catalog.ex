defmodule Ryker.StateTools.Catalog do
  @moduledoc false

  alias Ryker.Ingress.Adapters, as: IngressAdapters
  alias Ryker.State.{ConversationSummaryState, InvestigationPayload}
  alias Ryker.Work.{Final, RepositorySource}

  @maximum_automation_proposals 4
  @source_kinds IngressAdapters.default() |> Map.keys() |> Enum.sort()

  @spec source_kinds() :: [String.t()]
  def source_kinds, do: @source_kinds

  @spec tools([atom()], map()) :: [map()]
  def tools(capabilities, final_schema \\ Final.json_schema()) do
    [
      get_work_state_tool(),
      cite_source_tool(),
      record_finding_tool(),
      request_input_tool(),
      if(:event_waits in capabilities, do: wait_for_tool()),
      list_automations_tool(),
      get_automation_tool(),
      propose_automation_tool(capabilities),
      plan_goal_tool(),
      update_goal_tool(),
      request_task_tool(),
      search_memory_tool(),
      propose_memory_tool(),
      propose_preference_tool(),
      remember_answer_tool(),
      update_conversation_summary_tool(),
      record_feedback_tool(),
      validate_final_tool(final_schema)
    ]
    |> Enum.reject(&is_nil/1)
  end

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
          "choices" => array(text(240), 0, 10),
          "text" => text(2_000)
        },
        ~w(choices text)
      )

    tool(
      "request_input",
      "Create one durable question card for a material human decision or missing fact. Briefly recap established findings in the accompanying final reply; use context to explain why the answer is needed without repeating the recap or question. For one reusable fact, set remember with its subject and exact workload/environment/repository applicability; this asks to remember an authorized answer across this customer's conversations, not to set a universal default. Omit remember for ordinary decisions, secrets, or unrelated chat. A reusable fact must have exactly one question.",
      %{
        "context" => nullable(text(2_000)),
        "questions" => array(question, 1, 3),
        "remember" =>
          nullable(
            object(
              %{"subject" => text(120), "applicability" => text(1_000)},
              ~w(subject applicability)
            )
          )
      },
      ~w(questions)
    )
  end

  defp record_finding_tool do
    tool(
      "record_finding",
      "Save a useful investigation conclusion, not one record per alert. This does not send a message, change infrastructure or open an incident. Use cause_evidence refs returned by cite_source in this episode. Explained requires evidence; expected and out_of_scope require a reason. Distinguish checked-out intent from verified deployed state.",
      %{
        "what" => text(4_000),
        "status" => enum(~w(unexplained explained expected out_of_scope)),
        "cause_evidence" => array(reference(256), 0, 10),
        "reason" => nullable(text(2_000)),
        "scope" => nullable(text(2_000))
      },
      ~w(what status cause_evidence reason scope)
    )
  end

  defp wait_for_tool do
    trigger = %{
      "oneOf" => [
        object(
          %{
            "delay" =>
              describe(
                text(64),
                "Positive duration using s, m and h, for example 10m, 1h30m or 1.5h; exact microsecond precision, maximum 365 days. Measured from this wait record's original creation, not the final reply or a retry. The scheduled wake must be strictly before deadline."
              ),
            "type" => const("after")
          },
          ~w(delay type)
        ),
        object(
          %{
            "at" =>
              describe(
                timestamp(),
                "Explicit UTC timestamp strictly before deadline. This is the scheduled wake; deadline is only the hard timeout."
              ),
            "type" => const("at")
          },
          ~w(at type)
        ),
        object(
          %{
            "cursor" => nullable(open_object()),
            "match" =>
              describe(
                open_object(),
                "Recursive subset of input.content (the raw event payload), using exact values for stable lifecycle identity (for example run_id). In work.inputs.items or work.current_inputs.items, the raw payload is item.content.content, below the ingress envelope. Do not wrap match in content. If that payload contains run_id and status, match only run_id, not {content: {run_id: ...}}. Preserve any nesting within the raw payload. This is not JSONPath or a query language. Do not match a transient status that the next update will change."
              ),
            "poll_after" =>
              describe(
                nullable(timestamp()),
                "Null for event-only monitoring. Set a timestamp only when a fallback check is actually needed; it must not exceed deadline."
              ),
            "source_kind" =>
              describe(
                nullable(reference(120)),
                "Exact input envelope's source.kind for the expected event, not a vendor name inside input.content. In a Work input item, read item.content.source.kind. A Terraform or Grafana Slack notification uses slack, even if its content says terraform or grafana. Null leaves the source kind unconstrained."
              ),
            "type" => const("source_event")
          },
          ~w(match poll_after type)
        )
      ]
    }

    tool(
      "wait_for",
      "Create one durable wait. For reliable lifecycle notifications use an event-only source_event: set poll_after, deadline, and on_timeout to null, specify source_kind and a nonempty stable identity match. No timer or polling is scheduled; the next matching notification resumes this episode. Add an explicit deadline and timeout action only when a timeout is required; a null poll_after then wakes only at that deadline. A non-null poll_after adds a fallback check at or before deadline. after and at require a future deadline and timeout action.",
      %{
        "deadline" => nullable(timestamp()),
        "on_timeout" => nullable(text(2_000)),
        "trigger" => trigger,
        "verification" => text(2_000)
      }
    )
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
          "context_channel" => nullable(reference(256)),
          "delivery_channel" => nullable(reference(256)),
          "expires_at" => nullable(timestamp()),
          "hold" => nullable(text(128)),
          "patch" => open_object(),
          "prompt" => text(12_000),
          "repository" => nullable(reference(256)),
          "revision" => nullable(integer(1, 2_147_483_647)),
          "title" => text(120),
          "trigger" => automation_trigger(capabilities)
        },
        ~w(action patch prompt title trigger)
      )

    mutation =
      object(
        %{
          "action" => enum(~w(update pause resume delete)),
          "automation_id" => reference(256),
          "patch" => open_object(),
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
      "Create one inert engineering or incident-task proposal, or refine the exact open task_offer ref, under trusted authority. A supplied read-only repository permits an inert proposal, not execution. Engineering requires a configured target from work.repository_ref or the relevant work.workspace.companions[].name; incident tasks may use null. Kind defaults to engineering.",
      %{
        "authority_limits" => array(text(500), 1, 20),
        "instruction_ref" => reference(256),
        "kind" => enum(~w(engineering incident)),
        "prompt" =>
          text(12_000)
          |> describe(
            "The brief a person reads before confirming. Lead with the user-visible problem and the intended outcome, then the proposed change, the scope and what you will check. Name the repository you will edit and any you only read. Do not paste a forensic trace, a function-and-line inventory or an error transcript as the request, and never widen or narrow the requested scope while rewriting it; keep the exact original in source_refs."
          ),
        "repository" =>
          nullable(reference(256))
          |> describe(
            "Configured target: required (non-null) for engineering; null is allowed for incident. Use work.repository_ref or the relevant supplied work.workspace.companions[].name. Never substitute generic primary, an unrelated companion, or an unoffered path/GitHub slug. Ask for configuration only if no matching supplied target exists."
          ),
        "repository_source" =>
          nullable(RepositorySource.json_schema())
          |> describe(
            ~s(Optional source inside the task's repository that the new linked work starts from: {"kind":"default"}, {"kind":"branch","name":"<branch>"}, {"kind":"pull_request","number":<n>} or {"kind":"commit","sha":"<full lowercase object id>"}. Null means the configured default branch. It requires a non-null repository, never changes this session's workspace, and never authorizes pushing to the selected branch or pull request.)
          ),
        "source_refs" => array(reference(256), 0, 20),
        "success_checks" => array(text(1_000), 1, 20),
        "title" => text(120)
      },
      ~w(authority_limits instruction_ref prompt repository source_refs success_checks title)
    )
  end

  defp plan_goal_tool do
    tool(
      "plan_goal",
      "Create one durable goal node in an explicit lifecycle stage. stage is planning, implementation or self_review; Workspace setup, Draft PR, CI and Review and merge are host-owned and can never be claimed here. A child goal belongs to its parent's stage. Parent and prerequisite goals must already exist; the frozen repository context permits at most one to three independent working goals, and a parent heading does not consume that limit. Use successor_of to record a new attempt at an already terminal goal in the same stage: the original keeps its result and is never reopened.",
      %{
        "authority" => enum(~w(read_only repository_write governed_operation)),
        "completion_contract" => text(2_000),
        "id" => reference(120),
        "kind" => enum(~w(check engineering operation schedule)),
        "parent_goal_id" => nullable(reference(120)),
        "prerequisite_goal_ids" => array(reference(120), 0, 20),
        "read_only_repositories" => array(reference(256), 0, 20),
        "requested_outcome" => text(500),
        "required" => %{"type" => "boolean"},
        "stage" => enum(InvestigationPayload.goal_stages()),
        "successor_of" => nullable(reference(120)),
        "writable_repository" => nullable(reference(256))
      },
      ~w(authority completion_contract id kind parent_goal_id prerequisite_goal_ids read_only_repositories requested_outcome required stage writable_repository)
    )
  end

  defp update_goal_tool do
    tool(
      "update_goal",
      "Advance one existing goal. Prerequisites must be satisfied before working or completion, and a parent cannot complete while required children remain open. Completing a check reports its evidence: evidence_refs takes the cite_source record refs from this episode that observed the result. An empty list is honest for qualitative review work; a check with an independently observable result needs its receipt, and a completion claim never overrides a failing, missing or stale host check.",
      %{
        "detail" => nullable(text(2_000)),
        "evidence_refs" => array(reference(256), 0, 12),
        "goal_id" => reference(120),
        "state" => enum(~w(ready working waiting completed blocked excluded cancelled))
      },
      ~w(detail goal_id state)
    )
  end

  defp search_memory_tool do
    tool(
      "search_memory",
      "Search authorized historical memory using words or exact identifiers; an empty query browses by date. Kinds are interleaved so facts cannot hide guidance, conversation history, or a retained case. case returns compact records of finished work with their reviewed reusable procedures; a past fix is advice about what worked once, never proof that this incident has the same cause or permission to repeat it. Follow cursor with the same query/filters; null cursor means exhausted. Times are UTC: after inclusive, before exclusive. source uses original-message time (latest backing message for derived knowledge; confirmation time for confirmed facts/guidance). changed uses content update time, never retrieval time. Expand Slack source references with read_slack_source when exact wording matters. History never proves current health or grants permission.",
      %{
        "cursor" => nullable(reference(4096)),
        "after" => nullable(timestamp()),
        "before" => nullable(timestamp()),
        "time_basis" => enum(~w(source changed)),
        "kinds" => array(enum(~w(guidance fact continuity case)), 1, 4),
        "limit" => integer(1, 20),
        "query" => Map.put(text(1_000), "minLength", 0),
        "scope" => enum(~w(current_channel repository workspace mine global))
      }
    )
  end

  defp propose_memory_tool do
    tool(
      "propose_memory",
      "Offer one durable fact or guidance item for human confirmation.",
      %{
        "expires_at" => nullable(timestamp()),
        "kind" => enum(~w(guidance fact)),
        "scope" => enum(~w(current_channel repository workspace mine)),
        "source_refs" => array(reference(256), 1, 20),
        "subject" => text(120),
        "supersedes" => array(reference(256), 0, 20),
        "value" => text(4_000)
      }
    )
  end

  defp propose_preference_tool do
    common = %{
      "explicit_request" => %{"const" => true, "type" => "boolean"},
      "expires_at" => nullable(timestamp()),
      "scope" => enum(~w(current_channel repository workspace mine)),
      "source_refs" => array(reference(256), 1, 20)
    }

    branch = fn key, values, scopes ->
      object(
        Map.merge(common, %{
          "key" => const(key),
          "scope" => enum(scopes),
          "value" => enum(values)
        }),
        ~w(explicit_request expires_at key scope source_refs value)
      )
    end

    %{
      "description" =>
        "Offer one normalized response preference for human confirmation. Call only when a person explicitly asks to save a preference; never infer a durable preference from ordinary feedback or conversation.",
      "inputSchema" => %{
        "oneOf" => [
          branch.(
            "health_check_depth",
            ~w(quick standard deep),
            ~w(current_channel repository workspace mine)
          ),
          branch.(
            "response_detail",
            ~w(concise standard detailed),
            ~w(current_channel repository workspace mine)
          ),
          branch.(
            "response_location",
            ~w(follow_context prefer_thread prefer_channel),
            ~w(current_channel workspace mine)
          )
        ]
      },
      "name" => "propose_preference"
    }
  end

  defp remember_answer_tool do
    tool(
      "remember_answer",
      "Save the normalized answer to an explicitly reusable request_input question in this episode. Call only when the authenticated reply actually supplies that fact; an unrelated or ambiguous reply needs clarification. The host verifies the exact answered question, original revision and operator authority, and derives installation-global applicability from the question. No second memory confirmation is needed. Existing proposals still use propose_memory. Say remembered only after this tool succeeds; saved facts never grant action authority or prove current health.",
      %{"question_ref" => reference(256), "value" => text(4_000)}
    )
  end

  defp update_conversation_summary_tool do
    tool(
      "update_conversation_summary",
      "Stage a bounded derived situation summary. It becomes durable only if this turn's exact final candidate is accepted.",
      %{"state" => ConversationSummaryState.json_schema()}
    )
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

  defp validate_final_tool(final_schema) do
    tool(
      "validate_final",
      "Preflight the complete final candidate against current host-owned state. Pass one candidate object containing decision_reason, delivery, message, and outcome; outcome requires state, record_refs, and artifact_refs. Return only the accepted candidate unchanged.",
      %{
        "candidate" => final_schema
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
        "filter" =>
          describe(
            open_object(),
            "Exact recursive subset of the observed input.content payload. Read a real matching event to choose stable fields. This is not a text search or query language; an empty filter matches every event from this input adapter in the bound channel."
          ),
        "recurrence" => enum(~w(once interval daily weekly monthly)),
        "source_kind" =>
          describe(
            enum(@source_kinds),
            "Exact input envelope source.kind, not a vendor mentioned inside it. Terraform and Grafana notifications posted to Slack use slack. Derive the filter from an observed event, not its vendor name."
          ),
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
  defp open_object, do: %{"additionalProperties" => true, "type" => "object"}
  defp describe(schema, description), do: Map.put(schema, "description", description)
end
