defmodule Responder.Work.ValidatorTest do
  use ExUnit.Case, async: true

  alias Responder.Work.{Final, Validator}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "a complete reply accepts only existing records and artifacts without policing its prose" do
    candidate =
      candidate(
        %{
          "artifact_refs" => ["artifact:memory-chart:1"],
          "record_refs" => ["record:source:1"],
          "state" => "complete"
        },
        "I cannot yet explain the cause, but the requested file is attached."
      )

    context =
      context(%{
        artifacts: ["artifact:memory-chart:1"],
        records: %{"record:source:1" => record("source_citation")}
      })

    assert {:accept, accepted} = Validator.validate(candidate, context, @now)
    assert accepted.final.state == :complete
    assert accepted.result.continuation == %{"kind" => "complete"}
    assert accepted.result.delivery == :reply
    assert accepted.result.delivery_document == Final.document(accepted.final)
  end

  test "Slack typed entities are repaired in the same turn unless host authority permits them" do
    message = "Could [@Bruno](slack-user:U123) review this?"
    candidate = candidate(empty_outcome(), message)

    assert {:reject, violations} = Validator.validate(candidate, context(), @now)
    assert Enum.any?(violations, &String.contains?(&1, "non-Slack reply"))

    slack_mentions = %{
      "broadcasts" => [],
      "channels" => ["slack:T123:C456"],
      "user_groups" => [],
      "users" => ["slack-user:U123"],
      "workspace_ref" => "T123"
    }

    assert {:accept, _accepted} =
             Validator.validate(candidate, context(slack_mentions: slack_mentions), @now)

    denied = candidate(empty_outcome(), "Notify [@channel](slack-broadcast:channel).")

    assert {:reject, denied_violations} =
             Validator.validate(denied, context(slack_mentions: slack_mentions), @now)

    assert Enum.any?(denied_violations, &String.contains?(&1, "not authorized"))
  end

  test "shadow accepts read-only evidence but rejects every visible or effectful result" do
    records = %{
      "record:evidence:1" => record("evidence"),
      "record:offer:1" => record("task_offer")
    }

    assert {:reject, violations} =
             Validator.validate(
               candidate(
                 %{
                   "artifact_refs" => [],
                   "record_refs" => ["record:evidence:1", "record:offer:1"],
                   "state" => "complete"
                 },
                 "I would investigate this alert."
               ),
               context(execution_mode: "shadow", records: records),
               @now
             )

    assert Enum.any?(violations, &String.contains?(&1, "observe-only shadow"))
    assert Enum.any?(violations, &String.contains?(&1, "record:offer:1"))

    shadow_result =
      Jason.encode!(%{
        "decision_reason" => "Would record the current probe as supporting evidence.",
        "delivery" => "none",
        "message" => nil,
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => ["record:evidence:1"],
          "state" => "complete"
        }
      })

    assert {:accept, accepted} =
             Validator.validate(
               shadow_result,
               context(execution_mode: "shadow", records: records),
               @now
             )

    assert accepted.result.delivery == :none
  end

  test "engineering completion requires clean committed changes from this workspace" do
    final = candidate(empty_outcome(), "The requested implementation is complete.")

    assert {:reject, dirty_violations} =
             Validator.validate(
               final,
               context(workspace: workspace_changes(staged: 1, committed: 0)),
               @now
             )

    assert Enum.any?(dirty_violations, &String.contains?(&1, "uncommitted"))

    assert {:reject, unchanged_violations} =
             Validator.validate(
               final,
               context(workspace: workspace_changes(committed: 0)),
               @now
             )

    assert Enum.any?(unchanged_violations, &String.contains?(&1, "no committed task changes"))

    # Engineering work cannot claim the tree it inherited from the selected source
    # as its own completed change, whether that source is a branch, a pull request
    # or one exact commit.
    assert {:reject, inherited_tree_violations} =
             Validator.validate(
               final,
               context(
                 workspace:
                   workspace_changes(
                     committed: 1,
                     fork_tree: "tree-source",
                     admitted_source_tree: "tree-source"
                   )
               ),
               @now
             )

    assert Enum.any?(
             inherited_tree_violations,
             &String.contains?(&1, "beyond the admitted source")
           )

    # Review-only work that starts from the same source may finish unchanged only
    # when it committed nothing at all; that is the committed_count rule above.
    assert {:accept, _reviewed} =
             Validator.validate(
               final,
               context(
                 workspace:
                   workspace_changes(
                     committed: 2,
                     fork_tree: "tree-current",
                     admitted_source_tree: "tree-source"
                   )
               ),
               @now
             )

    assert {:accept, _accepted} =
             Validator.validate(
               final,
               context(workspace: workspace_changes(committed: 1)),
               @now
             )
  end

  test "generated artifacts are refused when the bound platform cannot deliver bytes" do
    candidate =
      candidate(
        %{
          "artifact_refs" => ["artifact:chart:1"],
          "record_refs" => [],
          "state" => "complete"
        },
        "The chart is attached."
      )

    assert {:reject, [violation]} =
             Validator.validate(
               candidate,
               context(artifacts: ["artifact:chart:1"], artifact_delivery_supported: false),
               @now
             )

    assert violation =~ "bound destination"
    assert violation =~ "artifact_refs"
  end

  test "a generated filename is repaired to its exact host-issued artifact reference" do
    candidate =
      candidate(
        %{
          "artifact_refs" => ["handoff-summary.png"],
          "record_refs" => [],
          "state" => "complete"
        },
        "The handoff chart is attached."
      )

    assert {:reject, [violation]} =
             Validator.validate(
               candidate,
               context(
                 artifact_metadata: [
                   %{
                     "id" => "artifact_6a93368352971a8d9c7aebf6",
                     "name" => "handoff-summary.png"
                   }
                 ],
                 artifacts: ["artifact_6a93368352971a8d9c7aebf6"]
               ),
               @now
             )

    assert violation =~ "handoff-summary.png"
    assert violation =~ "artifact_6a93368352971a8d9c7aebf6"
    assert violation =~ "Replace outcome.artifact_refs"
  end

  test "one rejection returns every actionable reference and visibility violation" do
    document = %{
      "decision_reason" => "No visible response is needed.",
      "delivery" => "none",
      "message" => nil,
      "outcome" => %{
        "artifact_refs" => ["artifact:missing"],
        "record_refs" => ["record:missing"],
        "state" => "complete"
      }
    }

    assert {:reject, violations} =
             Validator.validate(
               Jason.encode!(document),
               context(visible_reply_required: true),
               @now
             )

    assert length(violations) == 3
    assert Enum.any?(violations, &String.contains?(&1, "explicit human request"))
    assert Enum.any?(violations, &String.contains?(&1, "record:missing"))
    assert Enum.any?(violations, &String.contains?(&1, "artifact:missing"))
  end

  test "finalization waits for unresolved platform actions" do
    pending_ref = "platform-action:pending"

    assert {:reject, [violation]} =
             Validator.validate(
               candidate(
                 %{
                   "artifact_refs" => [],
                   "record_refs" => [pending_ref],
                   "state" => "complete"
                 },
                 "I am still acknowledging this."
               ),
               context(records: %{pending_ref => platform_action("reaction", "pending")}),
               @now
             )

    assert violation =~ "platform actions are unresolved"
    assert violation =~ pending_ref
  end

  test "a reaction-only final requires a delivered add covering the sole current human input" do
    delivered_ref = "platform-action:delivered"
    source_item_ref = "1787832000.000100"
    current_input = current_human_input("input:current", source_item_ref)

    reaction_only =
      Jason.encode!(%{
        "decision_reason" => "The delivered reaction fully acknowledges this social message.",
        "delivery" => "none",
        "message" => nil,
        "outcome" => %{
          "artifact_refs" => [],
          "record_refs" => [delivered_ref],
          "state" => "complete"
        }
      })

    assert {:accept, accepted} =
             Validator.validate(
               reaction_only,
               context(
                 records: %{
                   delivered_ref =>
                     platform_action("reaction", "delivered",
                       action: "add",
                       current_human_inputs: [current_input],
                       source_item_ref: source_item_ref
                     )
                 },
                 visible_reply_required: true
               ),
               @now
             )

    assert accepted.result.delivery == :none

    non_answers = [
      platform_action("reaction", "delivered",
        action: "remove",
        current_human_inputs: [current_input],
        source_item_ref: source_item_ref
      ),
      platform_action("reaction", "delivered",
        action: "add",
        current_human_inputs: [current_input],
        source_item_ref: "1787832000.000200"
      ),
      platform_action("reaction", "delivered",
        action: "add",
        current_human_inputs: [
          current_input,
          current_human_input("input:second", "1787832000.000200")
        ],
        source_item_ref: source_item_ref
      )
    ]

    Enum.each(non_answers, fn action ->
      assert {:reject, violations} =
               Validator.validate(
                 reaction_only,
                 context(
                   records: %{delivered_ref => action},
                   visible_reply_required: true
                 ),
                 @now
               )

      assert Enum.any?(violations, &String.contains?(&1, "explicit human request"))
    end)
  end

  test "a waiting result must reference exactly one matching durable wait" do
    wait = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "wait:operator:1"
    }

    candidate =
      candidate(
        %{
          "artifact_refs" => [],
          "record_refs" => ["record:question:1", "record:source:1"],
          "state" => "waiting_for_input"
        },
        "Which deployment should I inspect?"
      )

    context =
      context(
        records: %{
          "record:question:1" => record("operator_input", wait),
          "record:source:1" => record("source_citation")
        }
      )

    assert {:accept, accepted} = Validator.validate(candidate, context, @now)
    assert accepted.result.continuation == wait

    wrong_state =
      candidate(
        %{
          "artifact_refs" => [],
          "record_refs" => ["record:question:1"],
          "state" => "waiting_for_event"
        },
        "I will wait for the rollout."
      )

    assert {:reject, [violation]} = Validator.validate(wrong_state, context, @now)
    assert violation =~ "waiting_for_event"
    assert violation =~ "event wait"
  end

  test "an Emisar approval record is the exact event wait for a pending approval" do
    continuation = %{
      "deadline_at" => "2099-08-29T12:00:00.000000Z",
      "kind" => "wait",
      "wait_kind" => "event",
      "wait_ref" => "record:emisar:approval:1"
    }

    candidate =
      candidate(
        %{
          "artifact_refs" => [],
          "record_refs" => ["record:emisar:approval:1"],
          "state" => "waiting_for_event"
        },
        "Approval is required in Emisar. GitHub and Slack cannot approve this action."
      )

    context =
      context(
        records: %{
          "record:emisar:approval:1" => record("emisar_approval", continuation)
        }
      )

    assert {:accept, accepted} = Validator.validate(candidate, context, @now)
    assert accepted.result.continuation == continuation
    assert accepted.final.record_refs == ["record:emisar:approval:1"]
  end

  test "invalid JSON and an elapsed event wait receive self-contained correction text" do
    assert {:reject, [invalid_json]} = Validator.validate("not json", context(), @now)
    assert invalid_json =~ "not valid JSON"
    assert invalid_json =~ "attached output schema"

    elapsed = %{
      "deadline_at" => "2026-08-28T11:59:59.000000Z",
      "kind" => "wait",
      "wait_kind" => "event",
      "wait_ref" => "wait:rollout:1"
    }

    candidate =
      candidate(
        %{
          "artifact_refs" => [],
          "record_refs" => ["record:wait:1"],
          "state" => "waiting_for_event"
        },
        "I will check after the event."
      )

    assert {:reject, [violation]} =
             Validator.validate(
               candidate,
               context(records: %{"record:wait:1" => record("event_wait", elapsed)}),
               @now
             )

    assert violation =~ "record:wait:1"
    assert violation =~ "deadline"
    assert violation =~ "new wait"
  end

  test "every malformed final receives the correction for the field that is wrong" do
    valid = Jason.decode!(candidate(empty_outcome(), "Done."))

    cases = [
      {"[]", "not a JSON object"},
      {Jason.encode!(Map.delete(valid, "outcome")), "top-level object"},
      {Jason.encode!(%{valid | "delivery" => "later"}), "delivery must"},
      {Jason.encode!(%{valid | "message" => " "}), "message must"},
      {Jason.encode!(%{valid | "decision_reason" => "hidden"}), "provide message"},
      {Jason.encode!(%{valid | "outcome" => nil}), "outcome must"},
      {Jason.encode!(put_in(valid, ["outcome", "state"], "blocked")), "outcome.state"},
      {Jason.encode!(put_in(valid, ["outcome", "record_refs"], ["bad ref"])),
       "outcome.record_refs"},
      {Jason.encode!(put_in(valid, ["outcome", "artifact_refs"], ["bad ref"])),
       "outcome.artifact_refs"},
      {Jason.encode!(
         valid
         |> Map.put("delivery", "none")
         |> Map.put("message", nil)
         |> Map.put("decision_reason", "Wait silently.")
         |> put_in(["outcome", "state"], "waiting_for_input")
         |> put_in(["outcome", "record_refs"], ["record:wait:1"])
       ), "input-waiting outcome requires delivery reply"},
      {Jason.encode!(put_in(valid, ["outcome", "state"], "waiting_for_input")),
       "must reference the durable"}
    ]

    Enum.each(cases, fn {encoded, expected} ->
      assert {:reject, [violation]} = Validator.validate(encoded, context(), @now)
      assert violation =~ expected
    end)

    assert {:reject, [violation]} = Validator.validate(:not_json, context(), @now)
    assert violation =~ "not valid JSON"
  end

  test "validation context rejects malformed host records before judging the model" do
    candidate = candidate(empty_outcome(), "Done.")

    cases = [
      {nil, :type},
      {%{}, :fields},
      {Map.put(context(), "visible_reply_required", "yes"), :boolean},
      {Map.put(context(), "artifact_delivery_supported", "yes"), :boolean},
      {Map.put(context(), "artifact_refs", "artifact:1"), :artifact_refs},
      {Map.put(context(), "artifact_refs", ["artifact:1", "artifact:1"]), :artifact_refs},
      {Map.put(context(), "records", []), :records},
      {Map.put(context(), "records", %{"bad ref" => record("source")}), :record},
      {Map.put(context(), "records", %{"record:1" => %{"kind" => "source"}}), :record},
      {Map.put(context(), "records", %{"record:1" => record("source", "wait")}), :continuation},
      {Map.put(context(), "records", %{
         "record:1" => record("source", %{"kind" => "unknown"})
       }), :continuation}
    ]

    Enum.each(cases, fn {invalid_context, field} ->
      assert Validator.validate(candidate, invalid_context, @now) ==
               {:error, {:invalid_work_validation_context, field}}
    end)

    assert Validator.validate(candidate, context(), :not_a_datetime) ==
             {:error, {:invalid_work_validation_context, :now}}
  end

  test "a human question can retain one exact event-only watch without making it the active wait" do
    # The missing-project incident needed a human answer and continued custody of
    # the same Terraform run. Requiring a single record made those incompatible.
    input = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "record:question"
    }

    event = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "event",
      "wait_ref" => "record:watch"
    }

    records = %{
      "record:question" => record("input_request", input),
      "record:watch" => record("event_wait", event)
    }

    outcome =
      empty_outcome(%{
        "record_refs" => ["record:watch", "record:question"],
        "state" => "waiting_for_input"
      })

    assert {:accept, accepted} =
             Validator.validate(
               candidate(outcome, "Which project hosts this application?"),
               context(records: records),
               @now
             )

    assert accepted.result.continuation == input

    timed =
      put_in(
        records,
        ["record:watch", "continuation", "deadline_at"],
        "2099-08-28T12:30:00.000000Z"
      )

    assert {:reject, _} =
             Validator.validate(
               candidate(outcome, "Which project?"),
               context(records: timed),
               @now
             )
  end

  test "waiting and complete outcomes name exactly one compatible durable wait" do
    input_wait = %{
      "deadline_at" => nil,
      "kind" => "wait",
      "wait_kind" => "input",
      "wait_ref" => "wait:input"
    }

    second_input_wait = %{input_wait | "wait_ref" => "wait:second"}

    records = %{
      "record:input:1" => record("operator_input", input_wait),
      "record:input:2" => record("operator_input", second_input_wait),
      "record:source" => record("source")
    }

    cases = [
      {empty_outcome(%{"record_refs" => ["record:input:1"]}), "complete cannot reference"},
      {empty_outcome(%{
         "record_refs" => ["record:source"],
         "state" => "waiting_for_input"
       }), "no input wait was referenced"},
      {empty_outcome(%{
         "record_refs" => ["record:source"],
         "state" => "waiting_for_event"
       }), "no event wait was referenced"},
      {empty_outcome(%{
         "record_refs" => ["record:input:1", "record:input:2"],
         "state" => "waiting_for_input"
       }), "exactly one durable input wait"},
      {empty_outcome(%{
         "record_refs" => ["record:input:1", "record:input:2"],
         "state" => "waiting_for_event"
       }), "exactly one durable event wait"}
    ]

    Enum.each(cases, fn {outcome, expected} ->
      assert {:reject, violations} =
               Validator.validate(candidate(outcome, "Waiting."), context(records: records), @now)

      assert Enum.any?(violations, &String.contains?(&1, expected))
    end)
  end

  test "a complete result cannot abandon an open durable wait" do
    wait = %{
      "deadline_at" => "2099-08-28T12:30:00.000000Z",
      "kind" => "wait",
      "wait_kind" => "event",
      "wait_ref" => "wait:deployment:1"
    }

    complete = candidate(empty_outcome(), "The rollout is complete.")

    assert {:reject, [violation]} =
             Validator.validate(
               complete,
               context(records: %{"record:wait:1" => record("event_wait", wait)}),
               @now
             )

    assert violation =~ "record:wait:1"
    assert violation =~ "cannot be abandoned"
    assert violation =~ "outcome.record_refs"
  end

  test "a deliberate no-delivery result is accepted with its audited reason" do
    encoded =
      Jason.encode!(%{
        "decision_reason" => "This is the exact duplicate already handled above.",
        "delivery" => "none",
        "message" => nil,
        "outcome" => empty_outcome()
      })

    assert {:accept, accepted} = Validator.validate(encoded, context(), @now)
    assert accepted.result.delivery == :none
    assert accepted.result.decision_reason =~ "exact duplicate"
  end

  defp candidate(outcome, message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => outcome
    })
  end

  defp empty_outcome(overrides \\ %{}) do
    Map.merge(
      %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"},
      overrides
    )
  end

  defp context(overrides \\ []) do
    overrides = Map.new(overrides)
    artifacts = Map.get(overrides, :artifacts, [])

    %{
      "artifact_delivery_supported" => Map.get(overrides, :artifact_delivery_supported, true),
      "artifact_metadata" =>
        Map.get(overrides, :artifact_metadata, Enum.map(artifacts, &%{"id" => &1, "name" => &1})),
      "artifact_refs" => artifacts,
      "execution_mode" => Map.get(overrides, :execution_mode, "live"),
      "open_required_goals" => Map.get(overrides, :open_required_goals, []),
      "records" => Map.get(overrides, :records, %{}),
      "slack_mentions" => Map.get(overrides, :slack_mentions),
      "visible_reply_required" => Map.get(overrides, :visible_reply_required, false),
      "workspace" => Map.get(overrides, :workspace)
    }
  end

  defp workspace_changes(overrides) do
    overrides = Map.new(overrides)

    %{
      "base_commit" => "base",
      "committed_count" => Map.get(overrides, :committed, 0),
      "conflict_count" => Map.get(overrides, :conflicts, 0),
      "fork_head" => "fork",
      "fork_tree" => Map.get(overrides, :fork_tree, "tree-current"),
      "admitted_source_tree" => Map.get(overrides, :admitted_source_tree),
      "goal_ids" => ["implement-feature"],
      "repository" => "responder",
      "staged_count" => Map.get(overrides, :staged, 0),
      "unstaged_count" => Map.get(overrides, :unstaged, 0),
      "untracked_count" => Map.get(overrides, :untracked, 0)
    }
  end

  defp record(kind, continuation \\ nil),
    do: %{"continuation" => continuation, "kind" => kind}

  defp platform_action(kind, status, overrides \\ []) do
    overrides = Map.new(overrides)

    %{
      "action" => Map.get(overrides, :action, "add"),
      "action_kind" => kind,
      "continuation" => nil,
      "current_human_inputs" =>
        Map.get(overrides, :current_human_inputs, [
          current_human_input("input:current", "1787832000.000100")
        ]),
      "kind" => "platform_action",
      "source_item_ref" => Map.get(overrides, :source_item_ref, "1787832000.000100"),
      "status" => status,
      "tool" => "set_slack_reaction"
    }
  end

  defp current_human_input(input_ref, source_item_ref) do
    %{"input_ref" => input_ref, "source_item_ref" => source_item_ref}
  end
end
