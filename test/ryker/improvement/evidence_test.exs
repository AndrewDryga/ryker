defmodule Ryker.Improvement.EvidenceTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.Admission.Attempt
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{Actor, ConversationLab}
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Improvement
  alias Ryker.Improvement.{Candidate, Evidence, Prompt}
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.WorkProfile
  alias Ryker.Inspectors
  alias Ryker.Records.Record
  alias Ryker.RoutingExamples
  alias Ryker.Work.Turn

  @workspace "TIMPROVEEVIDENCE"
  @channel "CEVIDENCE"
  @now ~U[2026-09-27 12:00:00.000000Z]
  @bob "The payroll export still runs from the old billing box until Friday."

  # QA's draft existed, but its negative-rating analysis saw no publication
  # receipt and diagnosed from the model's wrong answer alone (2026-10-11).
  test "self-analysis sees canonical publication evidence without rewriting historical visibility" do
    %{episode: episode, publication: publication, receipt: receipt} =
      Ryker.Fixtures.Publication.published!("analysis-publication")

    question = message!("1790501100.000100", "Report the already opened draft.")
    Answers.join!(question, episode.id)
    unhappy!({:episode, episode.id}, "publication")
    candidate = Inspectors.improvement_candidate({:episode, episode.id})

    evidence = Evidence.gather(candidate)
    assert evidence.available?
    assert evidence.publication["state"]["published_revision"] == receipt
    assert evidence.publication["state"]["status"] == "published"
    assert evidence.publication["model_visibility"] == "not_proven"
    assert {:ok, _, _} = DateTime.from_iso8601(evidence.publication["observed_at"])

    prompt = evidence |> Prompt.build() |> Prompt.render()
    assert Jason.decode!(prompt)["context"]["publication"] == evidence.publication
    assert byte_size(prompt) <= Prompt.maximum_bytes()
    assert Prompt.instructions() =~ "does not prove what an earlier model saw"
    refute Map.has_key?(Evidence.case_snapshot(candidate).snapshot, "publication")

    settings = %{
      enabled: true,
      quiet_seconds: 0,
      lease_seconds: 60,
      policy: "analysis-publication",
      policy_digest: String.duplicate("a", 64)
    }

    assert {:ok, claim} = Ryker.Improvement.Analyses.claim("analysis-publication", settings)
    assert claim.candidate.id == candidate.id
    assert {:ok, run} = Ryker.Improvement.Analyses.prepare(claim, settings)

    assert Jason.decode!(run.prompt)["context"]["publication"]["state"]["published_revision"] ==
             receipt

    assert run.manifest["publication"]
    assert run.output_schema == Prompt.output_schema()

    # A malformed digest must not certify the publication's old receipt.
    publication.id
    |> Ryker.Publication.Publication.Query.by_id()
    |> Repo.update_all(set: [publication_receipt_fingerprint: String.duplicate("0", 64)])

    assert Evidence.gather(candidate).publication["state"]["published_revision"] == nil

    # Raw descriptions, patches and gate output are not analysis context.
    publication.id
    |> Ryker.Publication.Publication.Query.by_id()
    |> Repo.update_all(
      set: [body: "private-patch-not-context", title: "private-title-not-context"]
    )

    refute candidate |> Evidence.gather() |> Prompt.build() |> Prompt.render() =~ "private-"

    session = Repo.peek(Ryker.Work.Session.Query.latest_of_episode(episode.id))

    for repository <- [nil, "foreign-repository"] do
      episode.id
      |> Ryker.Work.Session.Query.by_episode_id()
      |> Repo.update_all(
        set: [
          repository_ref: repository,
          repository_source: if(is_nil(repository), do: nil, else: session.repository_source)
        ]
      )

      assert Evidence.gather(candidate).publication == nil
    end

    episode.id
    |> Ryker.Work.Session.Query.by_episode_id()
    |> Repo.update_all(
      set: [repository_ref: session.repository_ref, repository_source: session.repository_source]
    )

    # Tampering cannot certify a review, even if it retains the old fingerprint.
    huge_review =
      Map.put(publication.review_document, "gate", %{"status" => String.duplicate("x", 90_000)})

    publication.id
    |> Ryker.Publication.Publication.Query.by_id()
    |> Repo.update_all(set: [review_document: huge_review])

    tampered = Evidence.gather(candidate)

    assert %{"existing_pull_request" => %{"number" => 91}, "review" => nil} =
             tampered.publication["state"]

    assert byte_size(tampered |> Prompt.build() |> Prompt.render()) <= Prompt.maximum_bytes()

    # Even fingerprint-matched oversized metadata cannot consume the analysis bound.
    publication.id
    |> Ryker.Publication.Publication.Query.by_id()
    |> Repo.update_all(
      set: [review_fingerprint: Ryker.Publication.Review.fingerprint(huge_review)]
    )

    bounded = Evidence.gather(candidate)
    assert bounded.publication["state"] == nil
    assert bounded.publication["note"] =~ "safety bound"
    assert byte_size(bounded |> Prompt.build() |> Prompt.render()) <= Prompt.maximum_bytes()

    # Metadata alone must not resurrect a wordless/expired request for analysis.
    question.id
    |> Entry.Query.by_id()
    |> Repo.update_all(set: [operational_pruned_at: @now, content: %{"retention" => "pruned"}])

    assert %{available?: false, publication: nil} = Evidence.gather(candidate)
  end

  # Found in review before it shipped (2026-09-27). Routing examples are off
  # by default, so the analysis reads most routing prompts from the routing
  # attempt itself, which deleting and forgetting never reach. A prompt that
  # quoted Bob's thread message sent his words to the model after he had
  # deleted them, kept them in the analysis run's prompt and, once the
  # candidate was accepted, in the eval case and its download.
  test "a routing prompt is never read once a person deleted a message it quoted" do
    %{bob: bob, candidate: candidate} = request_quoting_bob!()

    # While nothing it quotes is gone, the analysis reads the attempt's own
    # prompt, and names Bob's message among those forgetting reaches it by.
    evidence = Evidence.gather(candidate)
    assert [%{"kept" => "attempt", "prompt" => prompt}] = evidence.routing
    assert prompt =~ @bob
    assert key(bob) in evidence.message_keys

    Answers.slack_message!(
      workspace: @workspace,
      channel: @channel,
      actor: "UBOB",
      text: "",
      ts: "1790500100.000100",
      thread: "1790500100.000100",
      kind: :delete,
      revision: 2,
      at: DateTime.add(@now, 180, :second)
    )

    evidence = Evidence.gather(Inspectors.improvement_candidate(Candidate.request(candidate)))
    assert [%{"kept" => "forgotten", "prompt" => nil, "answer" => nil}] = evidence.routing

    assert "Routing prompts that quoted something a person forgot, edited or deleted." in evidence.omitted

    refute CanonicalJSON.encode!(Prompt.build(evidence)) =~ "payroll"

    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    refute CanonicalJSON.encode!(accepted.case_evidence) =~ "payroll"
  end

  # An edit replaces the words a person no longer wants said. The analysis
  # read the routing prompt that quoted Bob's old words after he had
  # replaced them, and an accepted case kept them for a year.
  test "a routing prompt is never read once a person edited the words of a message it quoted" do
    %{candidate: candidate} = request_quoting_bob!()

    Answers.slack_message!(
      workspace: @workspace,
      channel: @channel,
      actor: "UBOB",
      text: "The payroll export moved to the new billing box.",
      ts: "1790500100.000100",
      thread: "1790500100.000100",
      kind: :edit,
      revision: 2,
      at: DateTime.add(@now, 180, :second)
    )

    evidence = Evidence.gather(Inspectors.improvement_candidate(Candidate.request(candidate)))
    assert [%{"kept" => "forgotten", "prompt" => nil, "answer" => nil}] = evidence.routing
    refute CanonicalJSON.encode!(Prompt.build(evidence)) =~ "old billing box"

    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    refute CanonicalJSON.encode!(accepted.case_evidence) =~ "old billing box"
  end

  # A person who edits their question after a wrong answer is unhappy with
  # it, so the edit itself makes the request a candidate, before any analysis
  # read it. The analysis then read the words the edit replaced from the
  # message's first revision, and an accepted case kept them for a year.
  test "the words a person replaced by editing their own message are never read" do
    %{alice: alice, candidate: candidate} = request_quoting_bob!()

    edit =
      Answers.slack_message!(
        workspace: @workspace,
        channel: @channel,
        actor: "UALICE",
        text: "Is the staging replica healthy?",
        ts: "1790500200.000100",
        thread: "1790500100.000100",
        kind: :edit,
        revision: 2,
        at: DateTime.add(@now, 180, :second)
      )

    # Routing joins an edit to the work that owns the message it edits.
    Answers.join!(edit, alice.episode_id)

    evidence = Evidence.gather(Inspectors.improvement_candidate(Candidate.request(candidate)))
    said = for %{"from" => "person"} = message <- evidence.conversation, do: message

    assert [
             %{"kind" => "message", "text" => nil, "note" => "edited by the person"},
             %{"kind" => "edit", "text" => "Is the staging replica healthy?"}
           ] = said

    assert "The words messages had before the person edited them." in evidence.omitted
    refute CanonicalJSON.encode!(Prompt.build(evidence)) =~ "Is the staging database healthy?"

    assert {:ok, accepted} = Improvement.accept(candidate.id, "control-plane:local")
    refute CanonicalJSON.encode!(accepted.case_evidence) =~ "Is the staging database healthy?"
    assert CanonicalJSON.encode!(accepted.case_evidence) =~ "Is the staging replica healthy?"
  end

  # A Chat reaction names its person as the console does, with a prefix the
  # message's sender lacks, so the asker's own thumbs down read as someone
  # else's (2026-10-04 review).
  test "a Chat reaction from the person who asked is theirs" do
    {:ok, profile} =
      WorkProfile.new(%{
        policy: "evidence-chat",
        policy_digest: String.duplicate("a", 64),
        repository_ref: nil
      })

    conversation = Ecto.UUID.generate()

    {:ok, %{entry: question}} =
      ConversationLab.send_message(
        conversation,
        "Summarize the deploy",
        profile
      )

    reply =
      Answers.work_reply!(
        question,
        "Nothing was deployed.",
        "control-plane-reply:#{conversation}",
        DateTime.add(question.occurred_at, 30, :second)
      )

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: Actor.person_ref(question.actor_ref),
               source: "control_plane",
               source_ref: "control-plane-reaction:#{conversation}",
               occurred_at: DateTime.add(question.occurred_at, 60, :second),
               request: {:episode, reply.episode.id}
             })

    evidence = Evidence.gather(Inspectors.improvement_candidate({:episode, reply.episode.id}))
    assert [%{"by" => "the person who asked"}] = evidence.feedback
  end

  # Routing's note on a person's feeling paraphrases their message, and it
  # stayed in the analysis after they deleted the message (2026-10-04 review).
  test "a feeling read from a message the person deleted is left out with it" do
    %{alice: alice, candidate: candidate} = request_quoting_bob!()

    upset =
      Answers.slack_message!(
        workspace: @workspace,
        channel: @channel,
        actor: "UALICE",
        text: "That is the wrong database, again.",
        ts: "1790500250.000100",
        thread: "1790500100.000100",
        at: DateTime.add(@now, 150, :second)
      )

    Answers.join!(upset, alice.episode_id)

    assert {:ok, _signal} =
             Feedback.record(%{
               kind: :sentiment,
               value: "frustrated",
               note: "Alice says it checked the wrong database again.",
               actor_ref: "UALICE",
               source: "slack",
               source_ref: Inbox.ref(upset),
               occurred_at: upset.occurred_at,
               request: Candidate.request(candidate)
             })

    deleted =
      Answers.slack_message!(
        workspace: @workspace,
        channel: @channel,
        actor: "UALICE",
        text: "",
        ts: "1790500250.000100",
        thread: "1790500100.000100",
        kind: :delete,
        revision: 2,
        at: DateTime.add(@now, 240, :second)
      )

    Answers.join!(deleted, alice.episode_id)

    evidence = Evidence.gather(Inspectors.improvement_candidate(Candidate.request(candidate)))
    assert [sentiment] = for(%{"kind" => "sentiment"} = signal <- evidence.feedback, do: signal)
    assert sentiment["note"] == nil
    refute CanonicalJSON.encode!(Prompt.build(evidence)) =~ "wrong database again"
  end

  # Evidence read a request's oldest sixty messages, so on a long thread the
  # analysis and the kept case lost the messages right before the feedback
  # (2026-10-04 review). It reads the newest sixty.
  test "a long request is read by its newest messages" do
    %{alice: alice, candidate: candidate} = request_quoting_bob!()

    for index <- 1..65 do
      ts = "17905004#{String.pad_leading("#{index}", 2, "0")}.000100"

      message =
        Answers.slack_message!(
          workspace: @workspace,
          channel: @channel,
          actor: "UALICE",
          text: "Follow-up #{index}",
          ts: ts,
          thread: "1790500100.000100",
          at: DateTime.add(@now, 200 + index, :second)
        )

      Answers.join!(message, alice.episode_id)
    end

    evidence = Evidence.gather(Inspectors.improvement_candidate(Candidate.request(candidate)))
    said = for %{"from" => "person", "text" => text} <- evidence.conversation, do: text

    assert "Follow-up 65" in said
    refute "Is the staging database healthy?" in said
  end

  # A Work turn past the operational horizon keeps neither its answer nor the
  # tools it called, and a quick reply goes at the horizon: the analysis read
  # an empty answer and no tools as if Ryker had said and done nothing
  # (2026-10-04 review).
  test "Ryker's answers older than Ryker keeps them are named as missing" do
    question = message!("1790500700.000100", "Is the staging database healthy?")
    reply = Answers.work_reply!(question, "Production is healthy.", "1790500700.000200", @now)
    unhappy!({:episode, reply.episode.id}, "expired-work")

    Repo.update_all(from(t in Turn, where: t.id == ^reply.turn.id),
      set: [operational_pruned_at: @now, delivery_document: %{"retention" => "pruned"}]
    )

    evidence = Evidence.gather(Inspectors.improvement_candidate({:episode, reply.episode.id}))

    assert "Ryker's answers and the tools it called in Work turns older than Ryker keeps them." in evidence.omitted

    quick = message!("1790500800.000100", "Count to three")
    Answers.quick_reply!(quick, "1, 2, 3", "1790500800.000200", @now)
    unhappy!({:input, quick.id}, "expired-quick")
    Repo.delete_all(from(r in RoutingResponse, where: r.input_id == ^quick.id))

    evidence = Evidence.gather(Inspectors.improvement_candidate({:input, quick.id}))
    assert "Ryker's quick reply, older than Ryker keeps it." in evidence.omitted
  end

  # A confirmed task reads the person's messages in the conversation that
  # offered it, and read none of Ryker's replies there, the offer included
  # (2026-10-04 review).
  test "a task's evidence holds Ryker's replies in the conversation that offered it" do
    question = message!("1790500900.000100", "Can you fix the deploy script?")

    offer =
      Answers.work_reply!(
        question,
        "I can open a pull request for that.",
        "1790500900.000200",
        @now
      )

    go = message!("1790501000.000100", "Go ahead")
    task = Answers.work_reply!(go, "Opened the pull request.", "1790501000.000200", @now)
    offered!(offer, task.episode.id)
    unhappy!({:episode, task.episode.id}, "task-offer")

    evidence = Evidence.gather(Inspectors.improvement_candidate({:episode, task.episode.id}))
    said = for %{"from" => "ryker", "text" => text} <- evidence.conversation, do: text

    assert "I can open a pull request for that." in said
    assert "Opened the pull request." in said
  end

  # The reviewer was asked to tell an instruction defect from a model that
  # ignored adequate instructions without seeing either: its evidence held
  # each Work turn's tool names and statuses, never the instructions, the
  # arguments, what came back or the corrections. Two saved diagnoses said so
  # (2026-10-16).
  test "a Work turn's evidence holds the instructions it ran with, each call and each correction" do
    question = message!("1790501000.000100", "Which revision is deployed?")
    reply = Answers.work_reply!(question, "I can't tell.", "1790501000.000200", @now)
    unhappy!({:episode, reply.episode.id}, "work-calls")
    secret = "sk-evidence-#{String.duplicate("z", 24)}"

    frozen!(reply.turn, "Frozen instructions of that release: close every gap you can.")

    Repo.update_all(from(t in Turn, where: t.id == ^reply.turn.id),
      set: [
        coop_turn_id: "coop-turn-evidence",
        validation_history: [
          %{
            "candidate_attempt" => 1,
            "verdict" => "reject",
            "violations" => [%{"message" => "Cite the run."}]
          },
          %{"candidate_attempt" => 2, "verdict" => "accept", "violations" => []}
        ]
      ]
    )

    call!(reply, 1, "run_action", %{"action_id" => "tfc.list_runs", "token" => secret},
      result: String.duplicate("run ", 400)
    )

    call!(reply, 3, "record_finding", %{"cause_evidence" => []},
      error: "invalid_arguments: 1 issue. /cause_evidence (max_items): takes at most 10 items."
    )

    # A key that names a credential keeps only the redaction marker.
    evidence = Evidence.gather(Inspectors.improvement_candidate({:episode, reply.episode.id}))

    # The turn's own frozen instructions, once, never today's.
    assert [
             %{
               "id" => "instructions-1",
               "text" => "Frozen instructions of that release: close every gap you can."
             }
           ] =
             evidence.instructions

    assert [turn] = evidence.work
    assert turn["instructions"] == "instructions-1"

    assert [run, finding] = turn["calls"]
    assert run["tool"] == "controller-tools.run_action"
    refute run["arguments"] =~ secret
    assert run["arguments"] =~ "tfc.list_runs"
    assert byte_size(run["result"]) <= 700
    assert finding["error"] =~ "/cause_evidence (max_items)"
    assert finding["result"] == nil

    assert [%{"attempt" => 1, "violations" => violations}] = turn["corrections"]
    assert violations =~ "Cite the run."
  end

  test "a call's arguments and result stay out once a person deleted a message of the request" do
    question = message!("1790501100.000100", "Check the payroll export host.")

    reply =
      Answers.work_reply!(question, "It runs on the billing box.", "1790501100.000200", @now)

    unhappy!({:episode, reply.episode.id}, "work-calls-deleted")

    Repo.update_all(from(t in Turn, where: t.id == ^reply.turn.id),
      set: [coop_turn_id: "coop-turn-deleted"]
    )

    call!(reply, 1, "run_action", %{"query" => "payroll export host"}, result: "billing-box-1")

    Answers.slack_message!(
      workspace: @workspace,
      channel: @channel,
      actor: "UALICE",
      text: "",
      ts: "1790501100.000100",
      kind: :delete,
      revision: 2,
      at: DateTime.add(@now, 180, :second)
    )

    evidence = Evidence.gather(Inspectors.improvement_candidate({:episode, reply.episode.id}))
    assert [%{"calls" => [call]}] = evidence.work
    assert call["tool"] == "controller-tools.run_action"
    assert {call["arguments"], call["result"]} == {nil, nil}

    assert "Work calls' arguments and results, which can quote a message a person deleted or changed." in evidence.omitted

    refute CanonicalJSON.encode!(Prompt.build(evidence)) =~ "payroll"
  end

  defp frozen!(turn, instructions) do
    prompt = Jason.encode!(%{"instructions" => instructions, "work" => %{"mode" => "full"}})

    Repo.update_all(from(t in Turn, where: t.id == ^turn.id),
      set: [submission: %{"prompt" => prompt, "output_schema" => %{"type" => "object"}}]
    )
  end

  # One call the worker reported for `reply`'s turn: started, then how it ended.
  defp call!(reply, sequence, tool, arguments, ending) do
    input = %{"arguments" => arguments, "server" => "controller-tools", "tool" => tool}
    call = "call-#{reply.turn.id}-#{sequence}"

    output =
      case Keyword.fetch(ending, :error) do
        {:ok, error} -> %{"error" => error, "result" => nil}
        :error -> %{"error" => nil, "result" => %{"content" => [%{"text" => ending[:result]}]}}
      end

    for {kind, offset, payload} <- [
          {"tool.started", 0, %{"input" => input, "tool_call_id" => call}},
          {"tool.completed", 1,
           %{
             "input" => input,
             "output" => output,
             "status" => "completed",
             "tool_call_id" => call
           }}
        ] do
      Repo.insert!(%Ryker.Work.ActivityEvent{
        coop_turn_id: Repo.get!(Turn, reply.turn.id).coop_turn_id,
        episode_id: reply.episode.id,
        kind: kind,
        occurred_at: DateTime.add(@now, sequence * 2 + offset, :second),
        payload: payload,
        payload_fingerprint: CanonicalJSON.digest(payload),
        remote_event_id: "#{call}:#{kind}",
        remote_session_id: "remote-session:#{reply.turn.session_id}",
        sequence: sequence * 2 + offset,
        session_id: reply.turn.session_id,
        version: 1
      })
    end
  end

  defp message!(ts, text) do
    Answers.slack_message!(
      workspace: @workspace,
      channel: @channel,
      actor: "UALICE",
      text: text,
      ts: ts
    )
  end

  defp unhappy!(request, event) do
    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: "UALICE",
               source: "slack",
               source_ref: "slack-event:evidence-#{event}",
               occurred_at: DateTime.add(@now, 60, :second),
               request: request
             })
  end

  # The task `task_episode_id` confirmed from the offer in `offer`'s reply.
  defp offered!(%{episode: episode, turn: turn}, task_episode_id) do
    Repo.insert!(%Record{
      id: Ecto.UUID.generate(),
      episode_id: episode.id,
      turn_id: turn.id,
      ref: "record:task_offer:#{Ecto.UUID.generate()}",
      operation_id: "offer-task",
      kind: "task_offer",
      status: :confirmed,
      payload: %{
        "kind" => "engineering",
        "title" => "Fix the deploy script",
        "repository" => "test"
      },
      payload_fingerprint: String.duplicate("a", 64),
      confirmed_episode_id: task_episode_id,
      confirmation_ref: "interaction:confirm-task",
      confirmed_by_actor_ref: "slack:user:UALICE",
      confirmed_at: @now
    })
  end

  # Alice asks in the thread Bob started, Ryker answers wrongly, and she
  # gives it a thumbs down: the request is a candidate, and the routing
  # decision about her message quoted Bob's.
  defp request_quoting_bob! do
    bob =
      Answers.slack_message!(
        workspace: @workspace,
        channel: @channel,
        actor: "UBOB",
        text: @bob,
        ts: "1790500100.000100"
      )

    alice =
      Answers.slack_message!(
        workspace: @workspace,
        channel: @channel,
        actor: "UALICE",
        text: "Is the staging database healthy?",
        ts: "1790500200.000100",
        thread: "1790500100.000100"
      )

    reply =
      Answers.work_reply!(
        alice,
        "The production database is healthy.",
        "1790500300.000100",
        DateTime.add(@now, 60, :second)
      )

    routed_quoting!(alice, bob)

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: "UALICE",
               source: "slack",
               source_ref: "slack-event:evidence-thumbs-down",
               occurred_at: DateTime.add(@now, 120, :second),
               request: {:episode, reply.episode.id}
             })

    %{
      alice: Repo.get!(Entry, alice.id),
      bob: bob,
      candidate: Inspectors.improvement_candidate({:episode, reply.episode.id})
    }
  end

  # What routing froze beside the decision about `entry` quotes `quoted` as
  # its thread's root, and the committed attempt's prompt holds its words, as
  # a real routing turn records them.
  defp routed_quoting!(%Entry{} = entry, %Entry{} = quoted) do
    context = %{
      "conversation_context" => %{
        "root" => %{
          "source_message_ref" => quoted.source_item_ref || quoted.native_input_id,
          "text" => @bob
        }
      }
    }

    Repo.update_all(
      from(input in Entry, where: input.id == ^entry.id),
      set: [
        admission_context: context,
        admission_context_fingerprint: CanonicalJSON.digest(context)
      ]
    )

    submission = %{
      "prompt" =>
        "Thread root (UBOB): #{@bob}\nCurrent message (UALICE): Is the staging database healthy?",
      "output_schema" => %{"type" => "object"}
    }

    Repo.insert!(%Attempt{
      input_id: entry.id,
      generation: entry.execution_generation,
      policy: "admission-read-only",
      policy_digest: String.duplicate("a", 64),
      submission: submission,
      submission_fingerprint: CanonicalJSON.digest(submission),
      execution_target: "codex/terra",
      phase: "committed",
      response: %{"assistant_message" => ~s({"action":"start_episode"})}
    })
  end

  defp key(%Entry{} = entry) do
    RoutingExamples.message_key(
      entry.destination_conversation_ref,
      entry.source_item_ref || entry.native_input_id
    )
  end
end
