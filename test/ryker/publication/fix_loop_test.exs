defmodule Ryker.Publication.FixLoopTest do
  @moduledoc """
  What Ryker does, without a person, about a task's change its trusted review
  refused (`Ryker.Publication.FixLoop`).

  Andrew, 2026-09-28, after Coop's review refused a task's committed change and
  its card said "Reply in this thread to ask me to fix it": "why I should ask it
  myself, it should be automatic feedback loop, agent needs to get errors from
  CI, fix them without me doing a man in the middle." Every refused change sat
  until a person typed what the review had already said.
  """
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]

  import Ecto.Query

  alias Ryker.Artifacts
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Publication.Custody, as: PublicationCustody
  alias Ryker.Publication.{GateOutput, Publication}
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.Slack.{Renderer, TaskCardProjection}

  alias Ryker.Work.{
    Custody,
    DeliveryReceipt,
    Result,
    Session,
    SessionChangeset,
    Submission,
    SubmissionBuilder
  }

  @now ~U[2026-09-28 12:00:00.000000Z]

  # Coop's paged read of a review gate's output, as an adapter will serve it:
  # one page per cursor, the last with no next cursor.
  defmodule PagedGate do
    def read_review_gate_output(pages, _session_id, _operation_id, cursor),
      do: {:ok, Map.fetch!(pages, cursor)}
  end

  # Andrew's request, 2026-09-28: a refusal the task's own work can fix goes
  # back to that work as a new turn in the same session, with the host's own
  # words for what failed, and its next commit is reviewed like any other. The
  # card that asked him to relay the review to the agent is what this replaces.
  test "a change whose checks fail is sent back to its work to fix, without a person" do
    %{claim: claim} = task_episode!("checks-fail")
    %{claim: work} = completed_turn!(claim, "checks-fail", "one")
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)

    assert %Publication{status: :review_ready} =
             review!(publication, "checks-fail", "one", refused(work))

    {request, blocked} = deliver_review!(publication, "checks-fail", "one")

    # The thread hears what failed and that Ryker is on it; nobody is asked to
    # reply, and no card offers a control that could only interrupt the fix.
    assert request.document == %{
             "message" =>
               "The repository's checks failed on the committed change. I'm fixing it now, attempt 1 of 3, and I'll check the new change when I'm done."
           }

    assert blocked.status == :blocked

    assert {:ok, episode} = Episodes.fetch_by_key(claim.episode.key)
    assert {episode.state, episode.owner_kind} == {:working, :turn}

    content = last_input_content!(claim.episode.key)
    assert content["kind"] == "publication_review_refusal"

    assert content["correction_request"] =~
             "Ryker's trusted review refused the committed change: the repository's checks failed on the committed change."

    assert content["correction_request"] =~
             "Run the repository's gate yourself to see what fails, fix it and commit."

    assert content["review"]["attempt"] == 1
    assert content["review"]["attempts"] == 3
    # No reader serves the gate's output yet, so the agent runs the gate itself.
    refute Map.has_key?(content["review"], "gate_output")

    # A new turn of the same worker session carries the refusal as its input.
    assert {:ok, fix} = Custody.claim_next("work:checks-fail:fix", 60, :work)
    assert fix.episode.id == claim.episode.id
    assert fix.session.id == work.session.id
    assert {:ok, submission} = SubmissionBuilder.build(fix)
    assert [current] = submission["context"]["current_inputs"]["items"]
    assert current["content"]["content"] == content

    # The host's own words carry no raw source, so Work may show them as they are.
    assert :ok =
             KnowledgeSnapshot.authorize_submission(
               fix.episode,
               fix.session.repository_ref,
               submission
             )

    # Its commit is reviewed by the ordinary path, on the same publication.
    finish_turn!(fix, "checks-fail", "fix")
    rearmed = Repo.get!(Publication, publication.id)
    assert rearmed.status == :review_pending
    assert rearmed.review_generation == blocked.review_generation + 1
    assert rearmed.fix_rounds == 1
  end

  # Andrew, 2026-09-28: "Ryker should get full access to errors, warnings and
  # all other output to work, like any llm model would, it's a sandbox!!" The
  # fix turn gets the failed gate's whole output as a file, read page by page
  # from Coop, with its end inline, instead of spending its first minutes
  # running the gate again to learn what the review already saw.
  test "the failed gate's complete output reaches the fix turn as a file, with its end inline" do
    %{claim: claim} = task_episode!("gate-output")
    %{claim: work} = completed_turn!(claim, "gate-output", "one")
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)
    failure = "FAILED test/parser_test.exs:12 expected :ok, got :retry\n"

    pages = %{
      nil => %{"output" => String.duplicate("compiling\n", 3_000), "next_cursor" => "page-2"},
      "page-2" => %{"output" => "warning: variable \"x\" is unused\n", "next_cursor" => "3"},
      "3" => %{"output" => failure, "next_cursor" => nil}
    }

    output = Enum.map_join([nil, "page-2", "3"], &pages[&1]["output"])
    review!(publication, "gate-output", "one", refused(work), {PagedGate, pages})
    deliver_review!(publication, "gate-output", "one")

    content = last_input_content!(claim.episode.key)

    assert content["correction_request"] =~
             "The gate's complete output is the attached gate-output.txt, and its end is in review.gate_output_end. Fix what fails, run the repository's gate again and commit."

    file = content["review"]["gate_output"]

    assert {file["name"], file["media_type"], file["bytes"]} ==
             {"gate-output.txt", "text/plain", byte_size(output)}

    assert byte_size(content["review"]["gate_output_end"]) == 16_384
    assert String.ends_with?(content["review"]["gate_output_end"], failure)
    assert {:ok, [%{"data" => ^output}]} = Artifacts.coop_inputs([file["artifact_ref"]])

    # The file travels with the fix turn itself.
    assert {:ok, fix} = Custody.claim_next("work:gate-output:fix", 60, :work)
    assert {:ok, submission} = SubmissionBuilder.build(fix)
    assert submission["input_artifact_refs"] == [file["artifact_ref"]]
  end

  # Coop will say plainly when it could not capture or keep a gate's output.
  # The agent hears that, and runs the gate itself, rather than a silence it
  # would read as a gate that printed nothing.
  test "Coop's word that it could not keep the gate's output reaches the fix turn" do
    %{claim: claim} = task_episode!("gate-output-lost")
    %{claim: work} = completed_turn!(claim, "gate-output-lost", "one")
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)
    pages = %{nil => %{"lost" => "the job's log was removed before the review read it"}}

    review!(publication, "gate-output-lost", "one", refused(work), {PagedGate, pages})
    deliver_review!(publication, "gate-output-lost", "one")

    content = last_input_content!(claim.episode.key)

    assert content["correction_request"] =~
             "Coop could not keep the gate's output (the job's log was removed before the review read it). Run the repository's gate yourself to see what fails, fix it and commit."

    refute Map.has_key?(content["review"], "gate_output")
  end

  # Coop keeps the first 64 MiB of a gate that prints without end. The agent
  # hears the file is not the whole run, rather than reading a cut log as all
  # the gate printed.
  test "Coop's word that it kept only part of the gate's output reaches the fix turn" do
    %{claim: claim} = task_episode!("gate-output-cut")
    %{claim: work} = completed_turn!(claim, "gate-output-cut", "one")
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)
    cut = "The check printed more than 64 MiB; Coop kept the first 64 MiB."

    pages = %{
      nil => %{
        "output" => "compiling\n",
        "next_cursor" => nil,
        "bytes" => 10,
        "complete" => false,
        "incomplete" => cut
      }
    }

    review!(publication, "gate-output-cut", "one", refused(work), {PagedGate, pages})
    deliver_review!(publication, "gate-output-cut", "one")

    content = last_input_content!(claim.episode.key)

    assert content["correction_request"] =~
             "The gate's output is the attached gate-output.txt, and its end is in review.gate_output_end. It is not the whole run: #{cut} Fix what fails, run the repository's gate again and commit."

    refute content["correction_request"] =~ "complete output"
  end

  # Andrew's request, 2026-09-28: at most three automatic fix rounds per
  # publication. A change the agent cannot fix would otherwise spend a worker
  # turn and a trusted review on the same failure forever; after the third the
  # task card says plainly that Ryker tried and the checks still fail, and a
  # person keeps Review latest state and Discard.
  test "the fix loop stops after three rounds and says so" do
    %{claim: claim, task: task} = task_episode!("capped")
    %{claim: work} = completed_turn!(claim, "capped", "one")
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)

    for round <- 1..3 do
      review!(publication, "capped", "r#{round}", refused(work))
      {request, blocked} = deliver_review!(publication, "capped", "r#{round}")
      assert request.document["message"] =~ "I'm fixing it now, attempt #{round} of 3"
      assert blocked.fix_rounds == round
      assert {:ok, fix} = Custody.claim_next("work:capped:#{round}", 60, :work)
      finish_turn!(fix, "capped", "fix-#{round}")
    end

    review!(publication, "capped", "r4", refused(work))
    {request, blocked} = deliver_review!(publication, "capped", "r4")

    assert request.document["message"] ==
             "I tried to fix it 3 times; the repository's checks still fail."

    assert [%{"kind" => "publication_review"}] = request.document["records"]
    assert blocked.status == :blocked
    assert blocked.fix_rounds == 3
    assert {:ok, %{state: :complete}} = Episodes.fetch_by_key(claim.episode.key)
    assert Custody.claim_next("work:capped:after", 60, :work) == {:ok, nil}

    assert {:ok, projection} = TaskCardProjection.build(Repo.get!(Record, task.id))
    card = projection.document["task_card"]
    assert card["status"] == "action_required"

    assert card["action_needed"] ==
             "I tried to fix it 3 times; the repository's checks still fail."

    assert card["publication"]["controls"] == ["update", "discard"]
  end

  # Andrew's request, 2026-09-28: the task card shows the loop plainly while it
  # runs. A card that still said "PR creation is blocked" beside Review latest
  # state, as it did for every refusal, sends a person to step into a fix that
  # is already under way; Discard stays, since stopping is always theirs.
  test "the task card shows the fix while it runs, with only Discard to press" do
    %{claim: claim, task: task} = task_episode!("card")
    %{claim: work} = completed_turn!(claim, "card", "one")
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)
    review!(publication, "card", "one", refused(work))
    deliver_review!(publication, "card", "one")

    assert {:ok, %{document: document}} = TaskCardProjection.build(Repo.get!(Record, task.id))
    card = document["task_card"]
    assert card["status"] == "queued"
    assert card["action_needed"] == nil
    assert card["publication"]["controls"] == ["discard"]

    assert card["publication"]["automatic_fix"] ==
             "Fixing: the repository's checks failed · attempt 1 of 3"

    # The audit projection names the task by its record; Slack's card by the card.
    assert {:ok, rendered} =
             Renderer.render(put_in(document, ["task_card", "task_ref"], "task-card:fix-loop"))

    blocks = Jason.encode!(rendered)
    assert blocks =~ "Fixing: the repository's checks failed · attempt 1 of 3"
    assert blocks =~ "ryker_task_discard_publication"
    refute blocks =~ "ryker_task_update_publication"
    refute blocks =~ "PR creation is blocked"
    refute blocks =~ "Action needed"

    assert {:ok, _fix} = Custody.claim_next("work:card:fix", 60, :work)
    assert {:ok, working} = TaskCardProjection.build(Repo.get!(Record, task.id))
    assert working.document["task_card"]["status"] == "working"
  end

  # Andrew's request, 2026-09-28: a finding such as a possible credential needs
  # a person. Sending it back to the agent would ask the model to decide, on its
  # own, what may leave the working copy — the one call the scan exists to take
  # away from it — and a failed gate beside the finding does not change that.
  test "a flagged credential is never looped automatically" do
    finding = "possible secret in lib/token.ex — remove the credential before publication"

    for {suffix, overrides} <- [
          {"credential",
           %{
             "candidate_retained" => false,
             "gate" => "passed",
             "not_publishable_reasons" => ["policy_findings"],
             "policy_findings" => [finding]
           }},
          {"credential-and-checks",
           %{
             "candidate_retained" => false,
             "not_publishable_reasons" => ["gate_failed", "policy_findings"],
             "policy_findings" => [finding]
           }}
        ] do
      %{claim: claim, request: request, blocked: blocked, admitted: admitted} =
        refuse!(suffix, overrides)

      assert request.document["message"] ==
               "I can't open a draft pull request for the committed change yet.",
             suffix

      assert [%{"kind" => "publication_review"}] = request.document["records"]
      assert blocked.status == :blocked
      assert blocked.fix_rounds == 0
      assert admitted == 0
      assert {:ok, %{state: :complete}} = Episodes.fetch_by_key(claim.episode.key)
      assert Custody.claim_next("work:#{suffix}:after", 60, :work) == {:ok, nil}
    end

    # The same failed checks without the finding go straight back to the work.
    assert %{admitted: 1, blocked: %{fix_rounds: 1}} = refuse!("credential-control", %{})
  end

  # Andrew's request, 2026-09-28: a base branch or working copy that moved
  # while the change was being checked says nothing about the change. It is
  # checked again as it is, with no fix turn spent and nothing posted; three
  # moves in a row stop, so a base branch that never holds still reaches a
  # person instead of a loop.
  test "a change checked while its base or working copy moved is checked again, without a fix turn" do
    %{claim: claim} = task_episode!("moved")
    %{claim: work} = completed_turn!(claim, "moved", "one")
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)
    events = length(Episodes.list_events(claim.episode.key))

    for {code, round} <- Enum.with_index(~w(parent_moved source_moved fork_owner_active), 1) do
      before = Repo.get!(Publication, publication.id)

      review =
        refused(work, %{
          "candidate_retained" => false,
          "gate" => "passed",
          "not_publishable_reasons" => [code]
        })

      rechecked = review!(publication, "moved", "r#{round}", review)

      assert rechecked.status == :review_pending, code
      assert rechecked.review_generation == before.review_generation + 1
      assert rechecked.recheck_rounds == round
      assert rechecked.review_document == nil
      assert rechecked.fix_rounds == 0
      assert DateTime.compare(rechecked.next_attempt_at, Repo.now!()) == :gt
      assert length(Episodes.list_events(claim.episode.key)) == events
      assert Custody.claim_next("work:moved:#{round}", 60, :work) == {:ok, nil}
      due_now!(publication)
    end

    stored =
      review!(
        publication,
        "moved",
        "r4",
        refused(work, %{
          "candidate_retained" => false,
          "gate" => "passed",
          "not_publishable_reasons" => ["parent_moved"]
        })
      )

    assert stored.status == :review_ready
    {request, blocked} = deliver_review!(publication, "moved", "r4")
    assert [%{"kind" => "publication_review"}] = request.document["records"]
    assert blocked.status == :blocked
    assert blocked.recheck_rounds == 3
    assert {:ok, %{state: :complete}} = Episodes.fetch_by_key(claim.episode.key)
  end

  # Andrew's request, 2026-09-28, asked which of the other refusals loop. A
  # change with no differences from its base has nothing left to fix, and
  # asking the agent to fix it invites a change nobody wanted; a repository
  # with no checks, or checks that could not start, is a setting or a machine,
  # and the agent writing the check that judges its own change is no check at
  # all. A reason this host cannot read is never guessed at. None of them loops.
  # Since 2026-10-01 ("Nobody should be clicking to update draft pr manually")
  # an unchecked change goes to the task's draft marked unverified; the rest
  # wait for a person.
  for {suffix, overrides, status} <- [
        {"no-changes",
         %{
           "candidate_retained" => false,
           "gate" => "passed",
           "not_publishable_reasons" => ["no_changes"]
         }, :blocked},
        {"no-checks", %{"gate" => "none", "not_publishable_reasons" => ["gate_not_configured"]},
         :publish_pending},
        {"checks-cannot-start",
         %{
           "gate" => "startup_error",
           "gate_error" => "docker: command not found",
           "not_publishable_reasons" => ["gate_startup_error"]
         }, :publish_pending},
        {"unreadable",
         %{
           "candidate_retained" => false,
           "not_publishable_reasons" => ["gate_failed", "lfs_object_missing"]
         }, :blocked}
      ] do
    @refusal {suffix, overrides, status}
    test "a refusal the work cannot fix never loops (#{suffix})" do
      {suffix, overrides, status} = @refusal
      %{request: request, blocked: refused, admitted: admitted} = refuse!(suffix, overrides)
      assert [%{"kind" => "publication_review"}] = request.document["records"]
      assert refused.status == status
      assert {refused.fix_rounds, refused.recheck_rounds} == {0, 0}
      assert admitted == 0
      assert Custody.claim_next("work:#{suffix}:after", 60, :work) == {:ok, nil}
    end
  end

  test "failed checks, the one refusal the work can fix, go back to it" do
    assert %{admitted: 1, blocked: %{fix_rounds: 1}} = refuse!("person-control", %{})
  end

  # A refusal that lands while a person's own follow-up is running must not
  # queue a fix request behind it: that turn's commit is reviewed afresh when it
  # finishes, and a queued "fix the failing checks" would then send the agent
  # after a review its own correction had already superseded.
  test "a refusal that lands while the task is still working leaves that work alone" do
    %{claim: claim} = task_episode!("busy")
    %{claim: work} = completed_turn!(claim, "busy", "one")
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)
    review!(publication, "busy", "one", refused(work))

    followup = admit_followup!(work, "person")
    assert {:ok, person} = Custody.claim_next("work:busy:person", 60, :work)
    assert person.turn.turn_ref == followup.turn_ref
    events = length(Episodes.list_events(claim.episode.key))

    {request, blocked} = deliver_review!(publication, "busy", "one")
    assert [%{"kind" => "publication_review"}] = request.document["records"]
    assert blocked.status == :blocked
    assert blocked.fix_rounds == 0
    assert {:ok, episode} = Episodes.fetch_by_key(claim.episode.key)
    assert episode.owner_ref == followup.turn_ref
    assert episode.queued_input_refs == []
    assert length(Episodes.list_events(claim.episode.key)) == events

    # The same refusal on a task at rest goes back to its work.
    assert %{admitted: 1, blocked: %{fix_rounds: 1}} = refuse!("busy-control", %{})
  end

  # One task whose first commit the review refuses, delivered: what the thread
  # was sent, the publication after it, and how many inputs it admitted.
  defp refuse!(suffix, overrides) do
    %{claim: claim} = task_episode!(suffix)
    %{claim: work} = completed_turn!(claim, suffix, "one")
    publication = Repo.get_by!(Publication, episode_id: claim.episode.id)
    events = length(Episodes.list_events(claim.episode.key))

    assert %Publication{status: :review_ready} =
             review!(publication, suffix, "one", refused(work, overrides))

    {request, blocked} = deliver_review!(publication, suffix, "one")

    %{
      admitted: length(Episodes.list_events(claim.episode.key)) - events,
      blocked: blocked,
      claim: claim,
      request: request
    }
  end

  # One confirmed engineering task on its own episode: the task record settles
  # on the first turn, and the session carries the workspace task that makes
  # every later completed turn a candidate for this task's own publication.
  defp task_episode!(suffix) do
    claim = claim_episode!(suffix)

    assert {:ok, task} =
             Records.create(Records.token(claim.turn), "task-#{suffix}", "task_offer", %{
               "kind" => "engineering",
               "prompt" => "Implement #{suffix} and run the focused checks.",
               "repository" => "ryker",
               "title" => "Implement #{suffix}"
             })

    settle_turn!(claim, suffix, "offer", [task.ref])

    {1, _rows} =
      Repo.update_all(
        from(record in Record, where: record.id == ^task.id),
        set: [
          confirmation_ref: "interaction:confirm:#{suffix}",
          confirmed_at: @now,
          confirmed_by_actor_ref: "slack:user:U-confirmer",
          confirmed_episode_id: claim.episode.id,
          status: :confirmed
        ]
      )

    session =
      Repo.get!(Session, claim.session.id)
      |> SessionChangeset.bind_workspace_task(%{
        "offer_ref" => task.ref,
        "prompt" => "Implement #{suffix} and run the focused checks.",
        "title" => "Implement #{suffix}"
      })
      |> Repo.update!()

    %{claim: %{claim | session: session}, task: task}
  end

  # A person's follow-up, admitted and completed: the turn commits, finishes and
  # carries the host's own `host:publication:ready` offer, exactly as
  # `Work.Executor` writes it, which arms or re-arms the task's review.
  defp completed_turn!(claim, suffix, label) do
    admit_followup!(claim, label)
    assert {:ok, work} = Custody.claim_next("work:#{suffix}:#{label}", 60, :work)
    %{claim: finish_turn!(work, suffix, label)}
  end

  defp finish_turn!(work, suffix, label) do
    work = bind_remote!(work)

    assert {:ok, _offer} =
             Records.create(
               Records.token(work.turn),
               "host:publication:ready",
               "publication_offer",
               %{
                 "body" => "Implemented #{suffix} on the #{label} pass.",
                 "title" => "Implement #{suffix}"
               }
             )

    settle_turn!(work, suffix, label, [])
    work
  end

  defp settle_turn!(work, suffix, label, record_refs) do
    final = %{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The #{label} change is committed.",
      "outcome" => %{"artifact_refs" => [], "record_refs" => record_refs, "state" => "complete"}
    }

    candidate = Jason.encode!(final)
    candidate_sha256 = digest(candidate)

    assert {:ok, _staged} =
             Custody.stage_candidate(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               nil,
               nil,
               candidate,
               candidate_sha256,
               1
             )

    assert {:ok, result} = Result.new(:reply, final)

    assert {:ok, _intent} =
             Custody.prepare_validation(
               work.episode.id,
               work.turn.turn_ref,
               work.lease_ref,
               candidate_sha256,
               1,
               :accept,
               result
             )

    assert {:ok, accepted} =
             Custody.accept_result(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               work.lease_ref,
               candidate_sha256,
               1,
               "validation:#{work.turn.id}"
             )

    assert {:ok, delivery} = Custody.claim_next("delivery:#{suffix}:#{label}", 60, :delivery)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               accepted.turn.delivery_ref,
               "slack",
               work.episode.destination_conversation_ref,
               work.episode.destination_thread_ref,
               "message:#{suffix}:#{label}:reply"
             )

    assert {:ok, _settled} =
             Custody.confirm_delivery(
               work.episode.id,
               work.episode.key,
               work.turn.turn_ref,
               delivery.lease_ref,
               receipt
             )
  end

  defp admit_followup!(claim, label) do
    command =
      EpisodeFixtures.admit_input(%{
        destination: %{
          conversation_ref: claim.episode.destination_conversation_ref,
          thread_ref: claim.episode.destination_thread_ref,
          transport: claim.episode.destination_transport
        },
        episode_id: claim.episode.id,
        episode_key: claim.episode.key,
        native_input_id: "followup:#{label}:#{claim.episode.id}",
        occurred_at: DateTime.utc_now(),
        payload: %{"text" => "Please make the #{label} change."},
        turn_ref: "turn:followup:#{label}:#{claim.episode.id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    command
  end

  # The review phase, as `Publication.Executor` runs it: with a reader, the
  # failed gate's output is read and kept beside the review.
  defp review!(publication, suffix, label, review, reader \\ nil) do
    assert {:ok, review_claim} =
             PublicationCustody.claim_next("publication:#{suffix}:#{label}:review", 60)

    assert review_claim.publication.id == publication.id

    assert {:ok, frozen} =
             PublicationCustody.freeze_review_revision(publication.ref, review_claim.lease_ref, 7)

    review = Map.put(review, "operation_id", "op-review-#{suffix}-#{label}")

    gate_output =
      with {api, client} <- reader, do: GateOutput.capture(api, client, frozen, review)

    assert {:ok, stored} =
             PublicationCustody.store_review(
               publication.ref,
               review_claim.lease_ref,
               frozen.review_generation,
               review,
               gate_output
             )

    stored
  end

  defp deliver_review!(publication, suffix, label) do
    assert {:ok, delivery_claim} =
             PublicationCustody.claim_next("publication:#{suffix}:#{label}:delivery", 60)

    assert delivery_claim.publication.id == publication.id
    assert {:ok, request} = PublicationCustody.delivery_request(delivery_claim.publication)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               request.ref,
               request.transport,
               request.conversation_ref,
               request.thread_ref,
               "message:#{suffix}:#{label}:review"
             )

    assert {:ok, confirmed} =
             PublicationCustody.confirm_delivery(
               publication.ref,
               delivery_claim.lease_ref,
               receipt
             )

    {request, confirmed}
  end

  defp due_now!(publication) do
    {1, _rows} =
      Repo.update_all(
        from(saved in Publication, where: saved.id == ^publication.id),
        set: [next_attempt_at: DateTime.add(Repo.now!(), -1, :second)]
      )
  end

  defp last_input_content!(episode_key) do
    episode_key
    |> Episodes.list_events()
    |> Enum.filter(&(&1.kind == :input_admitted))
    |> List.last()
    |> then(& &1.payload["payload"]["content"])
  end

  # Coop's refusal for #test's QA task (op_465712a7…, harvested 2026-09-10) in
  # this session's identity: the gate failed on a clean rebase, `gate_failed`
  # its only reason, the exact candidate retained.
  defp refused(claim, overrides \\ %{}) do
    claim
    |> review_document()
    |> Map.merge(%{
      "gate" => "failed",
      "not_publishable_reasons" => ["gate_failed"],
      "publishable" => false
    })
    |> Map.merge(overrides)
  end

  defp review_document(claim) do
    %{
      "candidate_head" => String.duplicate("6", 40),
      "candidate_tree" => String.duplicate("7", 40),
      "creation_base" => String.duplicate("1", 40),
      "gate" => "passed",
      "not_publishable_reasons" => [],
      "operation_id" => "op-review-#{claim.episode.id}",
      "parent_head" => String.duplicate("4", 40),
      "parent_tree" => String.duplicate("5", 40),
      "candidate_retained" => true,
      "patch_truncated" => false,
      "job_digest" => claim.session.worker_job_digest,
      "policy_findings" => [],
      "publishable" => true,
      "rebase" => "clean",
      "session_id" => claim.session.coop_session_id,
      "session_revision" => 7,
      "source_head" => String.duplicate("2", 40),
      "source_tree" => String.duplicate("3", 40)
    }
  end

  # Sandbox transactions hold conversation advisory locks until the test exits,
  # so every task has a destination of its own.
  defp claim_episode!(suffix) do
    id = Ecto.UUID.generate()
    workspace = "TFIXLOOP" <> (id |> digest() |> String.slice(0, 10) |> String.upcase())

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:#{workspace}:C456",
                   thread_ref: "thread:#{suffix}",
                   transport: "slack"
                 },
                 episode_id: id,
                 episode_key: "fix-loop:#{suffix}:#{id}",
                 native_input_id: "source:#{suffix}:#{id}",
                 occurred_at: @now,
                 payload: %{"text" => "Implement #{suffix}."},
                 turn_ref: "turn:#{suffix}:#{id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(id, "work-contributor", String.duplicate("a", 64), "ryker")

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60)
    bind_remote!(claim)
  end

  defp bind_remote!(claim) do
    WorkerJob.pin!(claim.session)

    assert {:ok, submission} =
             Submission.new(
               %{"input" => claim.episode.key},
               "Implement the frozen request.",
               %{"type" => "object"},
               "work-final-live-v3"
             )

    assert {:ok, frozen} =
             Custody.freeze_submission(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               submission
             )

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{claim.episode.id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               frozen.submit_generation,
               "coop-turn:#{claim.turn.id}"
             )

    %{claim | session: session, turn: turn}
  end
end
