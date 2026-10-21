defmodule Ryker.Behaviors.CorrectionsTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.Corrections
  alias Ryker.StateTools.FixedTools

  test "an explicit current correction is remembered without another confirmation" do
    # The earlier correction was saved only as a topic; the next review
    # repeated the omission. This uses its harvested words through the tool.
    correction = Corrections.correction!()

    assert {:ok, result} =
             FixedTools.call("remember_correction", correction.arguments,
               binding: correction.binding,
               answer_authorizer: fn _entry -> true end
             )

    assert result["status"] == "remembered"
    assert result["scope"] == "conversation"
    assert result["instruction"] == correction.arguments["instruction"]
    assert result["revision"] == 1
    offer = Repo.one!(Ryker.Records.Record.Query.by_ref(result["record_ref"]))
    assert offer.kind == "guidance_offer"
    assert offer.status == :confirmed
    assert {:ok, card} = Ryker.Delivery.ChatCard.project(offer)
    assert {"Expires", "No automatic expiry"} in card.details
  end

  test "an inferred instruction cannot be added to a person's exact correction" do
    correction = Corrections.correction!()
    arguments = %{correction.arguments | "instruction" => "Always deploy automatically."}
    assert {:error, error} = call(correction, arguments)
    assert error =~ "correction_not_quoted"
    refute Repo.exists?(Ryker.Behaviors.Behavior.Query.by_kind(:guidance))
  end

  test "only the current authenticated operator can make a durable correction" do
    correction = Corrections.correction!()

    assert FixedTools.call(
             "remember_correction",
             correction.arguments,
             binding: correction.binding,
             answer_authorizer: fn _ -> false end
           ) == {:error, "correction_unauthorized"}

    assert FixedTools.call(
             "remember_correction",
             correction.arguments,
             binding: correction.binding
           ) == {:error, "correction_unauthorized"}
  end

  test "a changed source cannot be remembered from an older frozen input" do
    correction = Corrections.correction!()
    revise!(correction, "Do not keep the earlier instruction.")
    assert call(correction, correction.arguments) == {:error, "correction_source_stale"}
  end

  test "taking back the source words withdraws the guidance" do
    correction = Corrections.correction!()
    assert {:ok, result} = call(correction, correction.arguments)
    revise!(correction, "Do not keep the earlier instruction.")
    behavior = Repo.one!(Ryker.Behaviors.Behavior.Query.by_ref(result["behavior_ref"]))
    assert behavior.status == :deleted
    refute inspect(behavior.payload) =~ correction.arguments["instruction"]
  end

  test "an assignment outside this episode cannot acquire a correction" do
    correction = Corrections.correction!()
    arguments = %{correction.arguments | "assignment_ref" => "behavior:another-automation"}
    assert call(correction, arguments) == {:error, "correction_assignment_mismatch"}
  end

  test "retries return the saved correction without creating another rule" do
    correction = Corrections.correction!()
    assert {:ok, first} = call(correction, correction.arguments)
    assert {:ok, repeated} = call(correction, correction.arguments)
    assert repeated["behavior_ref"] == first["behavior_ref"]
    assert repeated["status"] == "duplicate"
  end

  test "automated work receives the current conversation correction without a human asker" do
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    context = Ryker.Behaviors.model_context(correction.claim.episode, nil, nil)
    assert [guidance] = context["guidance"]
    assert guidance["behavior_ref"] == saved["behavior_ref"]
    assert guidance["revision"] == 1
    assert [%{"description" => description, "requirement_ref" => _}] = guidance["requirements"]
    assert description =~ "before/after"
    assert context["guidance_selection"]["included"] == 1
  end

  test "conversation corrections cannot leak into another conversation" do
    correction = Corrections.correction!(private: true)
    assert {:ok, _} = call(correction, correction.arguments)
    other = %{correction.claim.episode | destination_conversation_ref: "slack:TOTHER:COTHER"}
    assert Ryker.Behaviors.model_context(other, nil, nil)["guidance"] == []
  end

  test "a correction in one episode constrains a later rollout and accepts evidenced results" do
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    later = Corrections.later!(correction)
    assert later.episode.id != correction.claim.episode.id
    [guidance] = later.turn.submission["context"]["operator_context"]["guidance"]
    assert guidance["behavior_ref"] == saved["behavior_ref"]
    [requirement] = guidance["requirements"]

    candidate = recorded_candidate()
    context = Ryker.Work.ValidationContext.build(later.episode, later.turn)

    assert {:reject, violations} =
             Ryker.Work.Validator.validate(Jason.encode!(candidate), context, DateTime.utc_now())

    assert Enum.any?(violations, &String.contains?(&1, "required correction output"))

    evidence = evidence!(later)

    arguments = %{
      "guidance_ref" => saved["behavior_ref"],
      "revision" => 1,
      "requirement_ref" => requirement["requirement_ref"],
      "status" => "satisfied",
      "detail" => "Compared the deployment baseline, proposed source and application changes.",
      "evidence_refs" => [evidence.ref]
    }

    assert {:ok, result} = FixedTools.call("record_guidance_result", arguments, binding: later)

    candidate =
      put_in(candidate, ["outcome", "record_refs"], [result["record_ref"], evidence.ref])

    context = Ryker.Work.ValidationContext.build(later.episode, later.turn)

    assert {:accept, _} =
             Ryker.Work.Validator.validate(Jason.encode!(candidate), context, DateTime.utc_now())
  end

  test "unavailable evidence is an explicit blocked result rather than a satisfied correction" do
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    later = Corrections.later!(correction)
    [guidance] = later.turn.submission["context"]["operator_context"]["guidance"]
    [requirement] = guidance["requirements"]
    evidence = evidence!(later)

    arguments = %{
      "guidance_ref" => saved["behavior_ref"],
      "revision" => 1,
      "requirement_ref" => requirement["requirement_ref"],
      "status" => "blocked",
      "detail" =>
        "Apply history was checked; the planned image remains hidden after checking plan and startup evidence.",
      "evidence_refs" => []
    }

    assert {:error, error} = FixedTools.call("record_guidance_result", arguments, binding: later)
    assert error =~ "evidence_refs"

    assert {:ok, result} =
             FixedTools.call(
               "record_guidance_result",
               %{arguments | "evidence_refs" => [evidence.ref]},
               binding: later
             )

    record = Repo.one!(Ryker.Records.Record.Query.by_ref(result["record_ref"]))
    assert record.payload["status"] == "blocked"
  end

  test "a result cannot satisfy an unoffered or withdrawn requirement" do
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    later = Corrections.later!(correction)
    [guidance] = later.turn.submission["context"]["operator_context"]["guidance"]
    [requirement] = guidance["requirements"]
    evidence = evidence!(later)

    arguments = %{
      "guidance_ref" => saved["behavior_ref"],
      "revision" => 1,
      "requirement_ref" => requirement["requirement_ref"],
      "status" => "satisfied",
      "detail" => "The comparison was checked.",
      "evidence_refs" => [evidence.ref]
    }

    assert {:error, error} =
             FixedTools.call("record_guidance_result", %{arguments | "revision" => 2},
               binding: later
             )

    assert error =~ "guidance_requirement_stale"
    revise!(correction, "Do not keep the earlier instruction.")
    assert {:error, error} = FixedTools.call("record_guidance_result", arguments, binding: later)
    assert error =~ "guidance_requirement_stale"
  end

  test "a bot cannot turn its own words into durable operator guidance" do
    correction = Corrections.correction!(actor_kind: :bot)
    assert call(correction, correction.arguments) == {:error, "correction_unauthorized"}
  end

  test "replacement names the exact revision and a retry cannot resurrect superseded guidance" do
    correction = Corrections.correction!()
    assert {:ok, first} = call(correction, correction.arguments)

    arguments = %{
      correction.arguments
      | "guidance_ref" => first["behavior_ref"],
        "expected_revision" => first["revision"],
        "requirements" => ["Compare both source revisions."]
    }

    assert {:ok, replacement} = call(correction, arguments)
    assert replacement["behavior_ref"] != first["behavior_ref"]

    assert call(correction, correction.arguments) ==
             {:error,
              "correction_guidance_stale: reread the current guidance reference and revision before replacing it. Nothing was remembered."}

    assert {:ok, duplicate} = call(correction, arguments)
    assert duplicate["status"] == "duplicate"
    assert duplicate["behavior_ref"] == replacement["behavior_ref"]
    [current] = Ryker.Behaviors.model_context(correction.claim.episode, nil, nil)["guidance"]
    assert current["behavior_ref"] == replacement["behavior_ref"]
  end

  test "assignment corrections reach a later matching automation and no other work" do
    correction = Corrections.correction!()
    assignment = Corrections.assignment!(correction)
    arguments = %{correction.arguments | "assignment_ref" => assignment.ref}
    assert {:ok, saved} = call(correction, arguments)
    other_episode = %{correction.claim.episode | id: Ecto.UUID.generate()}
    assert Ryker.Behaviors.model_context(other_episode, nil, nil)["guidance"] == []
    later = Corrections.later!(correction, assignment: assignment)
    [guidance] = later.turn.submission["context"]["operator_context"]["guidance"]
    assert guidance["behavior_ref"] == saved["behavior_ref"]
    assert guidance["assignment_ref"] == assignment.ref
  end

  test "saved and accepted corrections are not reported as delivered follow-through" do
    for {module, function, arguments} <- Ryker.ControlPlane.ImprovementPage.subscriptions(),
        do: apply(module, function, arguments)

    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)

    candidate = %Ryker.Improvement.Candidate{
      id: Ecto.UUID.generate(),
      episode_id: correction.claim.episode.id
    }

    assert followthrough(candidate).state == :saved
    later = Corrections.later!(correction)
    [guidance] = later.turn.submission["context"]["operator_context"]["guidance"]
    [requirement] = guidance["requirements"]
    evidence = evidence!(later)

    assert {:ok, result} =
             FixedTools.call(
               "record_guidance_result",
               %{
                 "guidance_ref" => saved["behavior_ref"],
                 "revision" => 1,
                 "requirement_ref" => requirement["requirement_ref"],
                 "status" => "satisfied",
                 "detail" => "The retained sources establish both revisions and their changes.",
                 "evidence_refs" => [evidence.ref]
               },
               binding: later
             )

    document =
      put_in(recorded_candidate(), ["outcome", "record_refs"], [
        result["record_ref"],
        evidence.ref
      ])

    flush_episode_updates()
    accepted = Corrections.accept!(later, document)
    episode_id = later.episode.id
    assert_receive {:episode_updated, ^episode_id}
    assert followthrough(candidate).state == :accepted
    flush_episode_updates()
    Corrections.deliver!(later, accepted)
    assert_receive {:episode_updated, ^episode_id}
    assert followthrough(candidate).state == :followed
    assert followthrough(candidate).followed == 1
  end

  test "correction output capacity leaves room for evidence in the final result" do
    # A final accepts 64 record refs. Unbounded required outputs would create
    # a host correction the model could never satisfy, regardless of its work.
    correction = Corrections.correction!()

    source = %{
      conversation_ref: correction.claim.episode.destination_conversation_ref,
      episode: correction.claim.episode,
      turn: correction.claim.turn
    }

    for index <- 1..2 do
      behavior =
        Ryker.Fixtures.SavedEntities.behavior!(
          source,
          :guidance,
          %{
            "expires_in" => "30d",
            "repository" => nil,
            "scope" => "conversation",
            "subject" => "Existing outputs #{index}",
            "text" => "Check the required outputs.",
            "summary" => "Check the required outputs.",
            "visibility" => "conversation"
          },
          scope_ref: source.conversation_ref
        )

      payload =
        Map.put(behavior.payload, "requirements", Enum.map(1..8, &"Output #{index}.#{&1}"))

      Repo.update!(Ryker.Behaviors.Behavior.Changeset.update(behavior, %{payload: payload}))
    end

    assert {:error, error} = call(correction, correction.arguments)
    assert error =~ "correction_capacity_reached"
  end

  test "withdrawal and superseded evidence invalidate a previously checked result" do
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    later = Corrections.later!(correction)
    [guidance] = later.turn.submission["context"]["operator_context"]["guidance"]
    [requirement] = guidance["requirements"]
    evidence = evidence!(later)

    assert {:ok, _} =
             FixedTools.call(
               "record_guidance_result",
               %{
                 "guidance_ref" => saved["behavior_ref"],
                 "revision" => 1,
                 "requirement_ref" => requirement["requirement_ref"],
                 "status" => "satisfied",
                 "detail" => "Both source revisions were compared.",
                 "evidence_refs" => [evidence.ref]
               },
               binding: later
             )

    digest = Ryker.Work.FinalPreflight.ledger_sha256(later.episode.id, 1, [], later.turn.id)
    assert [current] = Ryker.Work.GuidanceRequirements.context(later.turn)
    assert current["result"]["status"] == "satisfied"

    payload =
      Map.merge(evidence.payload, %{
        "observation" => "The first baseline was superseded.",
        "supersedes" => [evidence.ref]
      })

    assert {:ok, _} = Ryker.Records.create(later.state_token, "new-baseline", "evidence", payload)
    assert [current] = Ryker.Work.GuidanceRequirements.context(later.turn)
    assert is_nil(current["result"])

    refute digest ==
             Ryker.Work.FinalPreflight.ledger_sha256(later.episode.id, 1, [], later.turn.id)

    revise!(correction, "Do not keep the earlier instruction.")
    assert Ryker.Work.GuidanceRequirements.context(later.turn) == []
  end

  test "a conditional correction can record evidenced non-applicability without claiming success" do
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    later = Corrections.later!(correction)
    [guidance] = later.turn.submission["context"]["operator_context"]["guidance"]
    [requirement] = guidance["requirements"]
    # Host-contract adapter: evidence describes the current task's scope, not
    # a fabricated provider response or a real model's applicability judgment.
    assert {:ok, evidence} =
             Ryker.Records.create(later.state_token, "task-scope", "evidence", %{
               "claim_id" => "current-task",
               "source_name" => "current request",
               "source_type" => "slack",
               "observation" =>
                 "This request asks about a saved correction, not a deployment review.",
               "relation" => "supports"
             })

    assert {:ok, result} =
             FixedTools.call(
               "record_guidance_result",
               %{
                 "guidance_ref" => saved["behavior_ref"],
                 "revision" => 1,
                 "requirement_ref" => requirement["requirement_ref"],
                 "status" => "not_applicable",
                 "detail" =>
                   "The rollout-specific output does not apply to this request about guidance.",
                 "evidence_refs" => [evidence.ref]
               },
               binding: later
             )

    candidate =
      put_in(recorded_candidate(), ["outcome", "record_refs"], [
        result["record_ref"],
        evidence.ref
      ])

    context = Ryker.Work.ValidationContext.build(later.episode, later.turn)

    assert {:accept, _} =
             Ryker.Work.Validator.validate(Jason.encode!(candidate), context, DateTime.utc_now())

    accepted = Corrections.accept!(later, candidate)
    Corrections.deliver!(later, accepted)

    feedback = %Ryker.Improvement.Candidate{
      id: Ecto.UUID.generate(),
      episode_id: correction.claim.episode.id
    }

    assert followthrough(feedback).state == :not_applicable
    assert followthrough(feedback).followed == 0
  end

  test "a third-party preview cannot become the operator's reusable instruction" do
    fixture = File.read!("testdata/learning/retained-rollout-correction.json") |> Jason.decode!()
    instruction = hd(fixture["corrections"])["text"]

    correction =
      Corrections.correction!(
        content: %{
          "text" => "https://example.invalid/review",
          "attachments" => [%{"text" => instruction}]
        }
      )

    assert {:error, error} = call(correction, correction.arguments)
    assert error =~ "correction_not_quoted"
  end

  test "a cross-conversation input cannot persist a rule in its episode's different destination" do
    correction = Corrections.correction!(episode_conversation: "slack:TEVAL:COTHER")
    assert {:error, error} = call(correction, correction.arguments)
    assert error =~ "correction_unauthorized"
  end

  test "shadow work can observe correction guidance without impossible live output obligations" do
    correction = Corrections.correction!()
    assert {:ok, _} = call(correction, correction.arguments)
    later = Corrections.later!(correction, execution_mode: :shadow)
    assert later.episode.execution_mode == :shadow
    assert [_] = later.turn.submission["context"]["operator_context"]["guidance"]
    context = Ryker.Work.ValidationContext.build(later.episode, later.turn)
    assert context["guidance_requirements"] == []

    candidate =
      recorded_candidate()
      |> Map.merge(%{
        "delivery" => "none",
        "message" => nil,
        "decision_reason" => "Would compare the deployment revisions without posting."
      })

    assert {:accept, _} =
             Ryker.Work.Validator.validate(Jason.encode!(candidate), context, DateTime.utc_now())
  end

  test "optional operator guidance cannot hide a required conversation correction" do
    correction = Corrections.correction!()

    source = %{
      conversation_ref: correction.claim.episode.destination_conversation_ref,
      episode: correction.claim.episode,
      turn: correction.claim.turn
    }

    secondary_source = Ryker.Fixtures.SavedEntities.source!(source.conversation_ref)

    for index <- 1..100 do
      source = if index > 50, do: secondary_source, else: source

      Ryker.Fixtures.SavedEntities.behavior!(
        source,
        :guidance,
        %{
          "expires_in" => "30d",
          "repository" => nil,
          "scope" => "operator",
          "subject" => "Advisory #{index}",
          "text" => "Use concise explanations.",
          "summary" => "Use concise explanations.",
          "visibility" => "private"
        },
        scope_kind: :operator,
        scope_ref: "slack:user:UOPERATOR"
      )
    end

    assert {:ok, saved} = call(correction, correction.arguments)
    context = Ryker.Behaviors.model_context(correction.claim.episode, "slack:user:UOPERATOR", nil)
    assert Enum.any?(context["guidance"], &(&1["behavior_ref"] == saved["behavior_ref"]))
    assert context["guidance_selection"]["eligible"] == 101
  end

  test "an invalid newest result cannot resurrect an older satisfied result" do
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    later = Corrections.later!(correction)
    [guidance] = later.turn.submission["context"]["operator_context"]["guidance"]
    [requirement] = guidance["requirements"]
    first = evidence!(later)

    arguments = %{
      "guidance_ref" => saved["behavior_ref"],
      "revision" => 1,
      "requirement_ref" => requirement["requirement_ref"],
      "status" => "satisfied",
      "detail" => "The first observation appeared sufficient.",
      "evidence_refs" => [first.ref]
    }

    assert {:ok, _} = FixedTools.call("record_guidance_result", arguments, binding: later)

    assert {:ok, second} =
             Ryker.Records.create(later.state_token, "later-check", "evidence", %{
               first.payload
               | "observation" => "An additional required source could not be read."
             })

    assert {:ok, _} =
             FixedTools.call(
               "record_guidance_result",
               %{
                 arguments
                 | "status" => "blocked",
                   "detail" => "The later check leaves the result unverified.",
                   "evidence_refs" => [second.ref]
               },
               binding: later
             )

    assert {:ok, _} =
             Ryker.Records.create(
               later.state_token,
               "newer-check",
               "evidence",
               Map.merge(second.payload, %{
                 "supersedes" => [second.ref],
                 "observation" => "The later observation is no longer current."
               })
             )

    assert [current] = Ryker.Work.GuidanceRequirements.context(later.turn)
    assert is_nil(current["result"])
  end

  test "editing a correction's words clears old checks while a title-only edit retains them" do
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    {review, behavior} = stale_review!(saved["behavior_ref"])

    assert {:ok, _} =
             Ryker.Memories.resolve_review(
               review["review_ref"],
               :edit,
               "slack:user:UOPERATOR",
               behavior.workspace_ref,
               %{"subject" => "Deployment review", "value" => behavior.payload["text"]}
             )

    behavior = Repo.one!(Ryker.Behaviors.Behavior.Query.by_ref(behavior.ref))
    assert behavior.payload["requirements"] == correction.arguments["requirements"]
    {review, behavior} = stale_review!(behavior.ref)

    assert {:ok, _} =
             Ryker.Memories.resolve_review(
               review["review_ref"],
               :edit,
               "slack:user:UOPERATOR",
               behavior.workspace_ref,
               %{"subject" => "Deployment review", "value" => "Keep rollout replies concise."}
             )

    behavior = Repo.one!(Ryker.Behaviors.Behavior.Query.by_ref(behavior.ref))
    assert behavior.payload["requirements"] == []
  end

  test "different automation applicability or required outputs are never offered as duplicates" do
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    behavior = Repo.one!(Ryker.Behaviors.Behavior.Query.by_ref(saved["behavior_ref"]))

    source = %{
      conversation_ref: correction.claim.episode.destination_conversation_ref,
      episode: correction.claim.episode,
      turn: correction.claim.turn
    }

    payload =
      behavior.payload
      |> Map.take(~w(expires_in repository scope summary text visibility))
      |> Map.put("subject", "Another automation's review")

    second =
      Ryker.Fixtures.SavedEntities.behavior!(source, :guidance, payload,
        scope_ref: source.conversation_ref
      )

    payload =
      Map.merge(second.payload, %{
        "requirements" => ["Report migration changes."],
        "assignment_ref" => "behavior:another-automation",
        "assignment_identity" => "another-automation"
      })

    Repo.update!(Ryker.Behaviors.Behavior.Changeset.update(second, %{payload: payload}))
    assert {:ok, _} = Ryker.Memories.Reviews.refresh_reviews(behavior.workspace_ref, 60)
    reviews = Ryker.Inspectors.memory_reviews(behavior.workspace_ref)
    refute Enum.any?(reviews, &(&1["kind"] == "duplicate"))
  end

  test "withdrawing a correction dismisses its pending memory review" do
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    {review, _} = stale_review!(saved["behavior_ref"])
    revise!(correction, "Do not keep the earlier instruction.")
    assert is_nil(Ryker.Memories.pending_review(review["review_ref"]))
  end

  test "one delivered correction cannot verify another saved correction" do
    # Self-analysis must not label all repairs proved after only one succeeds.
    correction = Corrections.correction!()
    assert {:ok, saved} = call(correction, correction.arguments)
    behavior = Repo.one!(Ryker.Behaviors.Behavior.Query.by_ref(saved["behavior_ref"]))

    source = %{
      conversation_ref: correction.claim.episode.destination_conversation_ref,
      episode: correction.claim.episode,
      turn: correction.claim.turn
    }

    payload =
      behavior.payload
      |> Map.take(~w(expires_in repository scope summary text visibility))
      |> Map.put("subject", "Another automation's review")

    second =
      Ryker.Fixtures.SavedEntities.behavior!(source, :guidance, payload,
        scope_ref: source.conversation_ref
      )

    payload =
      Map.merge(second.payload, %{
        "requirements" => behavior.payload["requirements"],
        "assignment_ref" => "behavior:another-automation",
        "assignment_identity" => "another-automation",
        "correction_source" => behavior.payload["correction_source"]
      })

    Repo.update!(Ryker.Behaviors.Behavior.Changeset.update(second, %{payload: payload}))

    candidate = %Ryker.Improvement.Candidate{
      id: Ecto.UUID.generate(),
      episode_id: correction.claim.episode.id
    }

    later = Corrections.later!(correction)
    [guidance] = later.turn.submission["context"]["operator_context"]["guidance"]
    [requirement] = guidance["requirements"]
    evidence = evidence!(later)

    assert {:ok, result} =
             FixedTools.call(
               "record_guidance_result",
               %{
                 "guidance_ref" => saved["behavior_ref"],
                 "revision" => 1,
                 "requirement_ref" => requirement["requirement_ref"],
                 "status" => "satisfied",
                 "detail" => "Retained sources establish both revisions and their changes.",
                 "evidence_refs" => [evidence.ref]
               },
               binding: later
             )

    document =
      put_in(recorded_candidate(), ["outcome", "record_refs"], [
        result["record_ref"],
        evidence.ref
      ])

    accepted = Corrections.accept!(later, document)
    Corrections.deliver!(later, accepted)
    assert followthrough(candidate).state == :partial
  end

  defp flush_episode_updates do
    receive do
      {:episode_updated, _} -> flush_episode_updates()
    after
      0 -> :ok
    end
  end

  defp stale_review!(reference) do
    query = Ryker.Behaviors.Behavior.Query.by_ref(reference)
    old = DateTime.add(DateTime.utc_now(), -7200)
    Repo.update_all(query, set: [updated_at: old, last_used_at: nil, last_reviewed_at: nil])
    behavior = Repo.one!(query)
    assert {:ok, _} = Ryker.Memories.Reviews.refresh_reviews(behavior.workspace_ref, 60)
    reviews = Ryker.Inspectors.memory_reviews(behavior.workspace_ref)

    review =
      Enum.find(
        reviews,
        &(&1["kind"] == "stale" and
            Enum.any?(&1["entries"], fn entry -> entry["memory_ref"] == reference end))
      )

    assert review
    {review, behavior}
  end

  defp followthrough(candidate),
    do: Ryker.Improvement.correction_followthrough([candidate])[candidate.id]

  defp recorded_candidate do
    fixture = File.read!("testdata/learning/retained-rollout-correction.json") |> Jason.decode!()
    # Host-contract adapter: use the recorded failure's exact message with a
    # terminal envelope, without replaying the old episode's wait references.
    put_in(fixture["failed_reply"], ["outcome"], %{
      "artifact_refs" => [],
      "record_refs" => [],
      "state" => "complete"
    })
  end

  defp evidence!(binding) do
    # Host evidence fixture for the coverage contract; model quality is
    # evaluated separately against the harvested two-episode scenario.
    {:ok, record} =
      Ryker.Records.create(binding.state_token, "baseline", "evidence", %{
        "claim_id" => "baseline",
        "source_name" => "deployment history",
        "source_type" => "emisar",
        "observation" =>
          "Previous apply identifies the baseline revision; the proposed revision has a source comparison.",
        "relation" => "supports"
      })

    record
  end

  defp call(correction, arguments) do
    FixedTools.call("remember_correction", arguments,
      binding: correction.binding,
      answer_authorizer: fn _ -> true end
    )
  end

  defp revise!(correction, text) do
    attributes =
      Map.merge(correction.attributes, %{
        content: %{"text" => text},
        event_kind: :edit,
        event_ref: "edit:#{correction.entry.id}",
        revision: 2
      })

    {:ok, input} = Ryker.Slack.Input.new(attributes)
    assert {:ok, _} = Ryker.Ingress.Inbox.record(input)
  end
end
