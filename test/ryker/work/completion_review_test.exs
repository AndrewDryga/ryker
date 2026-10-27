defmodule Ryker.Work.CompletionReviewTest do
  use Ryker.DataCase, async: true
  import Ecto.Query
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias Ryker.Crypto
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Inspectors
  alias Ryker.Repo
  alias Ryker.TestSupport.FakeWorkCoopAPI
  alias Ryker.Work.{Cancellation, CompletionReview}
  alias Ryker.Work.CompletionReview.{FleetSession, Prompt, Run}
  alias Ryker.Work.{Custody, Dispatcher, Final, Session, Turn, ValidationContext}
  alias Ryker.Work.Executor.Validation

  defmodule PendingAPI do
    def operation_by_key(_client, _key) do
      :not_found
    end

    def create_session(_client, _key, _policy, _external_ref, _source) do
      {:ok, %{"operation" => %{"method" => "CreateRemoteSession", "state" => "running"}}}
    end
  end

  defmodule BusyAPI do
    def operation_by_key(_client, _key), do: :not_found

    def create_session(_client, _key, _policy, _external_ref, _source),
      do: {:error, :coop_worker_capacity_unavailable}
  end

  defmodule FailedExecutor do
    def run(_claim, _options) do
      {:error,
       {:work_turn_terminal, "failed", "output_contract_failed",
        "caller rejected semantic output after 3 attempts"}}
    end
  end

  # Boundary doubles exercise host decisions; they are not harvested model judgments.
  defp judgment(decision \\ "complete") do
    Jason.encode!(%{
      "decision" => decision,
      "dismiss_wait_refs" => [],
      "reason" => "The deployment evidence determines completion.",
      "requirements" => [
        %{
          "requirement" => "Verify the running deployment",
          "status" =>
            if decision == "complete" do
              "satisfied"
            else
              "unresolved"
            end,
          "evidence" => "The submitted evidence and available deployment tools."
        }
      ],
      "actions" =>
        if decision == "complete" do
          []
        else
          [
            %{
              "requirement" => "Verify the running deployment",
              "action" => "Read the deployed version from the available status endpoint.",
              "basis" => "The work context advertises the status endpoint."
            }
          ]
        end
    })
  end

  defp reviewed(settings, decision \\ "complete", options \\ []) do
    {:ok, api} =
      FakeWorkCoopAPI.start_link([judgment(decision)], Keyword.put(options, :review_only, true))

    {Map.merge(settings, %{api: FakeWorkCoopAPI, client: api}), api}
  end

  defp final(candidate) do
    {:ok, final} = candidate |> Jason.decode!() |> Final.parse()
    final
  end

  setup do
    id = Ecto.UUID.generate()
    command = EpisodeFixtures.admit_input(%{episode_id: id, episode_key: "completion:#{id}"})
    {:ok, _transition} = Episodes.apply(command)
    {:ok, _session} = WorkSessions.pin_episode(id, "work-read-only", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("completion:#{id}", 300, :work)
    Ryker.Fixtures.CompletionReview.attest!(claim)
    session = WorkerJob.pin!(claim.session)
    claim = %{claim | session: session}
    {:ok, submission} = Inspectors.submission(claim)
    context = Map.put(submission["context"], "completion_review_required", true)
    submission = Map.put(submission, "context", context)
    {:ok, turn} = Custody.freeze_submission(id, claim.turn.turn_ref, claim.lease_ref, submission)

    {:ok, session} =
      Custody.bind_session(
        id,
        turn.turn_ref,
        claim.lease_ref,
        session.generation,
        session.create_generation,
        "work-session:#{id}"
      )

    {:ok, turn} =
      Custody.bind_turn(
        id,
        turn.turn_ref,
        claim.lease_ref,
        session.generation,
        turn.submit_generation,
        "work-turn:#{id}"
      )

    claim = %{claim | session: session}

    # The response bytes were harvested, not composed for the assertion. Before
    # completion review, a structurally valid answer alone ended substantive work.
    candidate =
      "testdata/work/terraform-automation-recovery.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("invalid_validation_calls")
      |> hd()
      |> Jason.encode!()

    sha256 = Crypto.sha256_hex(candidate)

    {:ok, turn} =
      Custody.stage_candidate(id, turn.turn_ref, claim.lease_ref, nil, nil, candidate, sha256, 1)

    settings = %{
      api: PendingAPI,
      client: :review,
      lease_seconds: 300,
      validation_context: &ValidationContext.build(&1.episode, &1.turn)
    }

    %{claim: %{claim | turn: turn}, candidate: candidate, sha256: sha256, settings: settings}
  end

  test "a silent observation skips review, while silent task work still requires it", %{
    claim: claim
  } do
    refute CompletionReview.required?(claim, :none)

    assert CompletionReview.required?(
             %{claim | session: %{claim.session | workspace_task: %{}}},
             :none
           )

    assert CompletionReview.required?(claim, :reply)
  end

  test "a busy fleet yields the same review without spending the parent's retry budget", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    busy = %{settings | api: BusyAPI}

    for _ <- 1..5 do
      assert CompletionReview.review(claim, final(candidate), busy) ==
               {:error, {:work_poll_window_elapsed, :completion_review}}
    end

    assert Repo.aggregate(Run, :count) == 1
    assert Repo.get!(Turn, claim.turn.id).status == :pending
  end

  test("substantive work stays open until its completion evidence is reviewed", %{
    claim: claim,
    candidate: candidate,
    sha256: sha256,
    settings: settings
  }) do
    assert Validation.ensure_validation_intent(claim, candidate, sha256, 1, [], settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    assert Repo.get!(Turn, claim.turn.id).validation_intent == nil
  end

  test("an independent complete judgment authorizes the exact candidate once", %{
    candidate: candidate,
    claim: claim,
    settings: settings
  }) do
    {settings, api} = reviewed(settings)
    assert CompletionReview.review(claim, final(candidate), settings) == :ok
    assert CompletionReview.review(claim, final(candidate), settings) == :ok
    assert FakeWorkCoopAPI.state(api).submit_count == 1
    [run] = Repo.all(Run)
    assert run.status == :applied
    assert run.remote_stopped_at
    assert {:ok, session} = FleetSession.fetch_for_run(run)
    assert session.execution_kind == :completion_review
    assert session.worker_job_document["targets"] == claim.session.worker_job_document["targets"]
    assert session.worker_job_document["source"] == nil
    assert session.worker_job_document["environment"] == %{}
    # Every review in a live follow-up failed Authentication required: offline
    # jobs intentionally receive no provider broker. Keep workload egress denied,
    # but let the isolated reviewer authenticate to its selected model.
    assert session.worker_job_document["egress"] == %{
             "mode" => "filtered",
             "rules" => [],
             "export_destinations" => false
           }

    assert session.worker_job_document["companions"] == []
    assert session.worker_job_document["check"] == %{"argv" => [], "environment" => %{}}
    assert session.worker_job_document["mode"] == "normal"
    assert session.worker_job_document["repository_read_only"]

    assert Repo.exists?(
             from(e in Ryker.Accounting.Execution,
               where: e.kind == "completion_review" and e.source_id == ^run.id
             )
           )

    assert Repo.exists?(
             DateTime.utc_now()
             |> Ryker.Retention.Cleanup.Query.eligible()
             |> Session.Query.by_id(session.id)
           )

    # Query eligibility alone missed the second owner check under custody's lock;
    # every finished review then leaked its remote session instead of being reclaimed.
    assert {:ok, %{session: %{id: cleanup_id}}} =
             Ryker.Retention.Custody.claim_next("review-cleanup", 60)

    assert cleanup_id == session.id

    assert [briefing, response] = Ryker.ControlPlane.CompletionReviews.entries([claim.turn], [])
    assert briefing.title == "Completion review"
    assert briefing.owner == {:turn, claim.turn.id}
    assert response.owner == {:turn, claim.turn.id}
    assert response.sections |> hd() |> Map.fetch!(:artifact) |> Map.fetch!(:text) =~ "complete"

    html = render_component(&Ryker.ControlPlane.EpisodeRequest.render/1, request: briefing)

    for section <- [
          "System prompt",
          "Proposed answer",
          "Work context",
          "Earlier inputs",
          "Work records",
          "Tool observations",
          "Earlier reviews",
          "Review scope"
        ] do
      assert html =~ section
    end

    refute html =~ "Other fields"

    # Appending another attempt must not rewrite the earlier heading.
    for kind <- [:admission, :learning, :completion_review] do
      initial = %{briefing | source_kind: kind, generations: 1}
      later = %{initial | generations: 3}
      first_html = render_component(&Ryker.ControlPlane.EpisodeRequest.render/1, request: initial)
      later_html = render_component(&Ryker.ControlPlane.EpisodeRequest.render/1, request: later)
      assert first_html == later_html
    end
  end

  test "a failed reviewer explains the missing decision before its retry", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    # Three real reviews stopped with acp_protocol_error and no answer. The
    # timeline showed only timings, then Attempt 2, hiding why no reply arrived.
    assert CompletionReview.review(claim, final(candidate), settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    [run] = Repo.all(Run)

    run
    |> Ecto.Changeset.change(
      status: :rejected,
      error_code: "completion_review_provider_failed",
      stop_receipt: %{
        "kind" => "terminal_turn",
        "state" => "failed",
        "error_code" => "acp_protocol_error"
      },
      remote_stopped_at: DateTime.utc_now()
    )
    |> Repo.update!()

    assert CompletionReview.review(claim, final(candidate), settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    entries = Ryker.ControlPlane.CompletionReviews.entries([claim.turn], [])
    failure = Enum.find(entries, &(&1.phase == :result))
    retry = Enum.find(entries, &(&1.phase == :submission && &1.generation == 2))
    html = render_component(&Ryker.ControlPlane.EpisodeRequest.render/1, request: failure)
    assert html =~ "Completion review failed"
    assert html =~ "worker reported a protocol error"
    assert html =~ "No completion decision was produced"
    retry_html = render_component(&Ryker.ControlPlane.EpisodeRequest.render/1, request: retry)
    assert retry_html =~ "Retried after attempt 1 failed"
    assert retry_html =~ "#completion-review-#{run.id}-result"

    for {attributes, headline, explanation} <- [
          {%{status: :stale, error_code: "completion_review_stale"},
           "Completion review superseded", "evidence changed"},
          {%{status: :rejected, error_code: "completion_review_parent_stopped"},
           "Completion review cancelled", "parent work stopped"},
          {%{status: :rejected, error_code: nil}, "Completion review failed",
           "reason was not recorded"}
        ] do
      Run |> Repo.get!(run.id) |> Ecto.Changeset.change(attributes) |> Repo.update!()

      result =
        Ryker.ControlPlane.CompletionReviews.entries([claim.turn], [])
        |> Enum.find(&(&1.id == "completion-review-#{run.id}-result"))

      state_html = render_component(&Ryker.ControlPlane.EpisodeRequest.render/1, request: result)
      assert state_html =~ headline
      assert state_html =~ explanation
      refute state_html =~ "Model&#39;s reason"
    end
  end

  test "the real stale-evidence transition is not described as a failed worker", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    assert CompletionReview.review(claim, final(candidate), settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    [run] = Repo.all(Run)

    assert {:ok, ended} =
             Ryker.Work.CompletionReview.Custody.end_attempt(
               claim,
               run.id,
               :completion_review_stale
             )

    assert ended.status == :rejected

    assert {:ok, _stopped} =
             Ryker.Work.CompletionReview.Custody.record_uncreated_stop(claim, run.id)

    assert CompletionReview.review(claim, final(candidate), settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    entries = Ryker.ControlPlane.CompletionReviews.entries([claim.turn], [])
    result = Enum.find(entries, &(&1.id == "completion-review-#{run.id}-result"))
    retry = Enum.find(entries, &(&1.phase == :submission && &1.generation == 2))
    html = render_component(&Ryker.ControlPlane.EpisodeRequest.render/1, request: result)
    assert html =~ "Completion review superseded"
    refute html =~ "Completion review failed"

    assert render_component(&Ryker.ControlPlane.EpisodeRequest.render/1, request: retry) =~
             "attempt 1 was superseded"
  end

  test("an unresolved requirement becomes a concrete correction", %{
    candidate: candidate,
    claim: claim,
    settings: settings
  }) do
    {settings, _api} = reviewed(settings, "continue")
    assert {:reject, [correction]} = CompletionReview.review(claim, final(candidate), settings)
    assert correction =~ "Read the deployed version"
    [_briefing, response] = Ryker.ControlPlane.CompletionReviews.entries([claim.turn], [])
    html = render_component(&Ryker.ControlPlane.EpisodeRequest.render/1, request: response)
    assert html =~ "Keep working"
    assert html =~ "Read the deployed version"
    refute html =~ "Passed first time"
    assert Repo.get!(Turn, claim.turn.id).validation_intent == nil
  end

  # A live backup recovery consumed two corrections before review requested
  # independent work on candidate three. Coop stopped without ever sending that
  # instruction to its model. A continuation must carry the exact feedback,
  # preserve the rejected turn, and still require a new accepted answer.
  test "a final correction from completion review continues with its exact feedback",
       %{} = context do
    %{claim: stale_claim} = context
    {claim, judgment} = rejected_last_candidate!(context)
    reason = terminal_reason()

    assert Dispatcher.run_claim(stale_claim,
             executor: FailedExecutor,
             worker_ref: "review-repair"
           ) ==
             {:ok, {:deferred, {:work_rerun_pending, reason}}}

    stopped = Repo.get!(Turn, claim.turn.id)
    assert stopped.cancellation_intent["action"] == "transfer"

    assert stopped.cancellation_intent["transfer_ref"] ==
             "transfer:completion-review:#{stopped.id}"

    assert stopped.candidate == claim.turn.candidate
    assert stopped.validation_history == claim.turn.validation_history
    assert stopped.accepted_at == nil
    assert stopped.delivery_document == nil

    assert {:ok, stop} = Custody.claim_next("review-repair-stop", 300, :work)

    {:ok, receipt} =
      Cancellation.terminal_receipt(
        claim.session.coop_session_id,
        claim.turn.coop_turn_id,
        "failed",
        nil,
        "open",
        nil
      )

    assert {:ok, settled} =
             Custody.settle_cancellation(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               stop.lease_ref,
               receipt
             )

    assert {:ok, next} = Custody.claim_next("review-repair-next", 300, :work)
    assert next.turn.turn_ref == settled.episode.owner_ref
    assert next.session.id == claim.session.id
    assert next.turn.candidate == nil
    assert {:ok, submission} = Inspectors.submission(next)
    assert submission["context"]["completion_review_feedback"]["judgment"] == judgment
    assert submission["context"]["repository_ref"] == claim.session.repository_ref

    # The feedback is part of this native transcript only. A different worker
    # session must not gain the old review through this convenience projection.
    assert {:ok, other} =
             Inspectors.submission(%{next | session: %{next.session | id: Ecto.UUID.generate()}})

    refute Map.has_key?(other["context"], "completion_review_feedback")
  end

  for variant <- [:missing_review, :different_candidate, :different_rejection, :spent] do
    test "completion continuation refuses #{variant}", %{} = context do
      {claim, _judgment} = rejected_last_candidate!(context)

      case unquote(variant) do
        :missing_review ->
          Repo.delete_all(Run)

        :different_candidate ->
          Repo.update_all(Run, set: [candidate_sha256: String.duplicate("f", 64)])

        :different_rejection ->
          {:ok, _turn} =
            Custody.stage_candidate(
              claim.episode.id,
              claim.turn.turn_ref,
              claim.lease_ref,
              claim.turn.candidate_sha256,
              3,
              claim.turn.candidate,
              claim.turn.candidate_sha256,
              4
            )

          {:ok, _turn} =
            Custody.prepare_validation(
              claim.episode.id,
              claim.turn.turn_ref,
              claim.lease_ref,
              claim.turn.candidate_sha256,
              4,
              {:reject, ["Fix the output shape."]},
              nil
            )

        :spent ->
          ref = "turn:rerun:2:#{Ecto.UUID.generate()}"
          Repo.update_all(from(t in Turn, where: t.id == ^claim.turn.id), set: [turn_ref: ref])

          Repo.update_all(from(e in Episodes.Episode, where: e.id == ^claim.episode.id),
            set: [owner_ref: ref]
          )
      end

      claim = %{
        claim
        | turn: Repo.get!(Turn, claim.turn.id),
          episode: Repo.get!(Episodes.Episode, claim.episode.id)
      }

      assert Dispatcher.run_claim(claim, executor: FailedExecutor, worker_ref: "review-refused") ==
               {:ok, {:deferred, {:work_stop_pending, terminal_reason()}}}

      assert Repo.get!(Turn, claim.turn.id).cancellation_intent["action"] == "block"
    end
  end

  test "a reviewed correction cannot restart work after a person stops it", %{} = context do
    {claim, _judgment} = rejected_last_candidate!(context)

    assert {:ok, _request} =
             Custody.request_stop(
               claim.episode.id,
               claim.episode.key,
               claim.turn.turn_ref,
               "stop:review-continuation",
               "Stop this work."
             )

    assert Dispatcher.run_claim(claim, executor: FailedExecutor, worker_ref: "review-stop") ==
             {:ok, {:lease_lost, terminal_reason()}}

    assert Repo.get!(Turn, claim.turn.id).cancellation_intent["cancel_ref"] ==
             "stop:review-continuation"
  end

  # The automatic transfer used to take precedence over a later human Stop,
  # returning success while still starting another turn behind the person's back.
  for action <- [:stop, :cancel] do
    test "a person can #{action} a completion continuation already queued", %{} = context do
      {claim, _judgment} = rejected_last_candidate!(context)
      assert CompletionReview.continue_failed(claim) == {:ok, :continued}

      request_action =
        if unquote(action) == :stop, do: &Custody.request_stop/5, else: &Custody.request_cancel/5

      assert {:ok, request} =
               request_action.(
                 claim.episode.id,
                 claim.episode.key,
                 claim.turn.turn_ref,
                 "stop:queued-review-continuation",
                 "Stop this work."
               )

      assert request.turn.cancellation_intent["action"] ==
               if(unquote(action) == :stop, do: "block", else: "cancel")

      assert {:ok, stop} = Custody.claim_next("stop-queued-review", 300, :work)

      {:ok, receipt} =
        Cancellation.terminal_receipt(
          claim.session.coop_session_id,
          claim.turn.coop_turn_id,
          "failed",
          nil,
          "closed",
          nil
        )

      assert {:ok, settled} =
               Custody.settle_cancellation(
                 claim.episode.id,
                 claim.episode.key,
                 claim.turn.turn_ref,
                 stop.lease_ref,
                 receipt
               )

      assert settled.turn.status == if(unquote(action) == :stop, do: :blocked, else: :superseded)

      assert settled.turn.last_error_code ==
               if(unquote(action) == :stop, do: "operator_stop", else: "operator_cancelled")

      assert Repo.aggregate(Turn.Query.by_episode_id(claim.episode.id), :count) == 1
    end
  end

  defp rejected_last_candidate!(%{
         claim: claim,
         candidate: candidate,
         sha256: sha,
         settings: settings
       }) do
    review = File.read!("testdata/work/completion-review-last-correction.json")
    judgment = Jason.decode!(review)
    {:ok, api} = FakeWorkCoopAPI.start_link([review], review_only: true)
    settings = Map.merge(settings, %{api: FakeWorkCoopAPI, client: api})

    {:ok, turn} =
      Custody.stage_candidate(
        claim.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        sha,
        1,
        candidate,
        sha,
        3
      )

    claim = %{claim | turn: turn}
    assert {:reject, violations} = CompletionReview.review(claim, final(candidate), settings)

    {:ok, turn} =
      Custody.prepare_validation(
        claim.episode.id,
        turn.turn_ref,
        claim.lease_ref,
        sha,
        3,
        {:reject, violations},
        nil
      )

    {%{claim | turn: turn}, judgment}
  end

  defp terminal_reason do
    {:work_turn_terminal, "failed", "output_contract_failed",
     "caller rejected semantic output after 3 attempts"}
  end

  test("a review cannot authorize a different candidate", %{
    candidate: candidate,
    claim: claim,
    settings: settings
  }) do
    {settings, _api} = reviewed(settings)
    candidate = final(candidate)
    assert CompletionReview.review(claim, candidate, settings) == :ok
    changed = %{candidate | message: candidate.message <> " Additional claim."}

    assert Repo.transaction(fn -> CompletionReview.authorize_in_transaction(claim, changed) end) ==
             {:ok, {:error, :completion_review_required}}
  end

  test("a changed evidence ledger invalidates a completed review", %{
    candidate: candidate,
    claim: claim,
    settings: settings
  }) do
    {settings, _api} = reviewed(settings)
    candidate = final(candidate)
    assert CompletionReview.review(claim, candidate, settings) == :ok

    Repo.update_all(from(e in Episodes.Episode, where: e.id == ^claim.episode.id),
      inc: [semantic_version: 1]
    )

    assert Repo.transaction(fn -> CompletionReview.authorize_in_transaction(claim, candidate) end) ==
             {:ok, {:error, :completion_review_required}}
  end

  test("pending review is reused across repeated dispatcher polls", %{
    candidate: candidate,
    claim: claim,
    settings: settings
  }) do
    candidate = final(candidate)

    assert CompletionReview.review(claim, candidate, settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    assert CompletionReview.review(claim, candidate, settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    assert Repo.aggregate(Run, :count) == 1

    assert Repo.aggregate(
             from(s in Session, where: s.execution_kind == :completion_review),
             :count
           ) == 1
  end

  test("a reviewer that was never created is stopped before its parent", %{
    candidate: candidate,
    claim: claim,
    settings: settings
  }) do
    candidate = final(candidate)

    assert CompletionReview.review(claim, candidate, settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    assert CompletionReview.cancel(claim, settings) == :ok
    [run] = Repo.all(Run)
    assert run.stop_receipt == %{"kind" => "never_created"}
    assert run.remote_stopped_at
  end

  test("three unchanged attempts exhaust review without accepting", %{
    candidate: candidate,
    claim: claim,
    settings: settings
  }) do
    candidate = final(candidate)

    for n <- 1..3 do
      assert CompletionReview.review(
               claim,
               %{candidate | message: candidate.message <> " #{n}"},
               settings
             ) == {:error, {:work_poll_window_elapsed, :completion_review}}

      assert CompletionReview.cancel(claim, settings) == :ok
    end

    assert CompletionReview.review(claim, candidate, settings) ==
             {:error, :completion_review_budget_exhausted}

    assert Repo.get!(Turn, claim.turn.id).validation_intent == nil
  end

  test "a complete verdict with an unresolved requirement is invalid" do
    invalid =
      judgment()
      |> Jason.decode!()
      |> put_in(["requirements", Access.at(0), "status"], "unresolved")
      |> Jason.encode!()

    assert Prompt.parse(invalid) == {:error, :invalid_completion_review}
    assert Prompt.parse("The task is complete.") == {:error, :invalid_completion_review}
  end

  # The reviewer could reject a needless handoff but the open record forced
  # every later answer back into waiting, even after the missing fact was read.
  test "a rejected dependency can be dismissed so the same work can finish", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    for {kind, payload} <- [
          {"input_request", %{"question" => "Which running version?", "choices" => []}},
          {"event_wait",
           %{
             "deadline_at" => nil,
             "kind" => "deployment_health",
             "verification" => "Read the running version.",
             "event_matcher" => %{
               "type" => "source_event",
               "source_kind" => "deployment",
               "match" => %{"revision" => "fixture"},
               "poll_after" => nil,
               "on_timeout" => nil
             }
           }}
        ] do
      assert {:ok, wait} =
               Ryker.Records.create(
                 Ryker.Records.token(claim.turn),
                 "unneeded:#{kind}",
                 kind,
                 payload
               )

      state = if kind == "input_request", do: :waiting_for_input, else: :waiting_for_event
      waiting = %{final(candidate) | state: state, record_refs: [wait.ref]}

      review =
        judgment("continue")
        |> Jason.decode!()
        |> Map.put("dismiss_wait_refs", [wait.ref])
        |> Jason.encode!()

      {:ok, api} = FakeWorkCoopAPI.start_link([review], review_only: true)
      current = Map.merge(settings, %{api: FakeWorkCoopAPI, client: api})
      assert {:reject, [_feedback]} = CompletionReview.review(claim, waiting, current)
      assert Repo.get!(Ryker.Records.Record, wait.id).status == :dismissed
      refute Map.has_key?(Ryker.Records.validation_records(claim.episode.id), wait.ref)
    end

    {settings, _api} = reviewed(settings)
    assert CompletionReview.review(claim, final(candidate), settings) == :ok
  end

  test "a genuine person-only blocker without an addressee stays unfinished", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    Repo.update_all(from(o in Episodes.Origin, where: o.episode_id == ^claim.episode.id),
      set: [actor_ref: "system:monitor"]
    )

    refute Episodes.Origins.person_participated?(claim.episode.id)
    {settings, _api} = reviewed(settings, "request_input")

    assert CompletionReview.review(claim, final(candidate), settings) ==
             {:error, :completion_review_no_addressee}

    assert Repo.get!(Turn, claim.turn.id).validation_intent == nil
    refute Ryker.Records.question_open?(claim.episode.id)
  end

  test "review cost remains attributed to its parent repository", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    session =
      claim.session
      |> Ecto.Changeset.change(repository_ref: "fixture-repository")
      |> Repo.update!()

    claim = %{claim | session: session}
    {settings, _api} = reviewed(settings)
    assert CompletionReview.review(claim, final(candidate), settings) == :ok

    executions =
      Ryker.Accounting.Execution.Query.ledger(nil, "live")
      |> Ryker.ControlPlane.Usage.Query.dimensions()
      |> Ryker.ControlPlane.Usage.Query.by_dimension(:repository_ref, "fixture-repository")
      |> Repo.all()

    assert Enum.any?(executions, &(&1.kind == "completion_review"))
  end

  test "missing source attestation cannot be disclosed to a fresh reviewer", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    claim.session
    |> Ecto.Changeset.change(source_exposure_count: nil, knowledge_exposure_count: nil)
    |> Repo.update!()

    assert CompletionReview.review(claim, final(candidate), settings) ==
             {:error, :work_knowledge_context_stale}

    refute Repo.exists?(Run)
  end

  test "changed evidence is rechecked even when the review submission revision was already frozen",
       %{claim: claim, candidate: candidate, settings: settings} do
    assert CompletionReview.review(claim, final(candidate), settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    [run] = Repo.all(Run)
    assert {:ok, _run} = Ryker.Work.CompletionReview.Custody.freeze_submit(claim, run.id, 1)

    Repo.update_all(from(e in Episodes.Episode, where: e.id == ^claim.episode.id),
      inc: [semantic_version: 1]
    )

    assert Ryker.Work.CompletionReview.Custody.freeze_submit(claim, run.id, 1) ==
             {:error, :completion_review_evidence_changed}
  end

  # A freshness fence is a request to retry the review, never an operator block.
  test "evidence arriving after preparation keeps the work runnable", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    changed = fn _task ->
      Repo.update_all(from(e in Episodes.Episode, where: e.id == ^claim.episode.id),
        inc: [semantic_version: 1]
      )
    end

    {late, _api} = reviewed(settings, "complete", on_create_session: changed)

    assert CompletionReview.review(claim, final(candidate), late) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    assert Repo.get!(Turn, claim.turn.id).status == :pending

    assert CompletionReview.review(claim, final(candidate), late) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    {fresh, _api} = reviewed(settings)
    assert CompletionReview.review(claim, final(candidate), fresh) == :ok
  end

  test "late tool evidence invalidates a review before acceptance", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    {settings, _api} = reviewed(settings)
    candidate = final(candidate)
    assert CompletionReview.review(claim, candidate, settings) == :ok

    event = %{
      "id" => "late-evidence",
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "payload" => %{
        "tool_call_id" => "late-status",
        "status" => "completed",
        "output" => "The deployed version changed."
      },
      "sequence" => 1,
      "session_id" => claim.session.coop_session_id,
      "turn_id" => claim.turn.coop_turn_id,
      "type" => "tool.completed",
      "version" => 1
    }

    assert {:ok, _cursor} = Ryker.Work.Activity.ingest(claim.session.id, [event])

    assert Repo.transaction(fn -> CompletionReview.authorize_in_transaction(claim, candidate) end) ==
             {:ok, {:error, :completion_review_required}}
  end

  test "large escaped evidence is fitted instead of blocking an actionable request", %{
    claim: claim,
    candidate: candidate
  } do
    # Encoded previews escape their quoted JSON again. Their nominal budgets
    # formerly built a prompt over the submission cap and stopped useful work.
    output = String.duplicate("\\\"", 32_000)
    context = Map.put(claim.turn.submission["context"], "large_evidence", output)

    claim = %{
      claim
      | turn: %{claim.turn | submission: Map.put(claim.turn.submission, "context", context)}
    }

    event = %{
      "id" => "large-evidence",
      "occurred_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "payload" => %{"tool_call_id" => "large-read", "status" => "completed", "output" => output},
      "sequence" => 1,
      "session_id" => claim.session.coop_session_id,
      "turn_id" => claim.turn.coop_turn_id,
      "type" => "tool.completed",
      "version" => 1
    }

    events =
      for n <- 1..8, do: Map.merge(event, %{"id" => "large-evidence-#{n}", "sequence" => n})

    assert {:ok, _} = Ryker.Work.Activity.ingest(claim.session.id, events)

    assert {:ok, {:ok, snapshot}} =
             Repo.transaction(fn ->
               Ryker.Work.CompletionReview.Evidence.snapshot(claim, final(candidate))
             end)

    assert byte_size(Prompt.build(snapshot)) <= 224_000
    assert snapshot["tool_observations"]["items"]["truncated"]
    assert snapshot["tool_observations"]["omitted"] == 0

    assert {:ok, snapshot["ledger_sha256"]} ==
             Repo.transaction(fn -> Ryker.Work.CompletionReview.Evidence.fingerprint(claim) end)
  end

  test "the review contract accepts its allowed Unicode text lengths" do
    # The schema counts code points; a byte budget must fit all valid UTF-8,
    # or an otherwise valid review is refused before its decision is considered.
    review = judgment("continue") |> Jason.decode!()

    requirement = %{
      "requirement" => String.duplicate("界", 500),
      "evidence" => String.duplicate("界", 1000),
      "status" => "unresolved"
    }

    review = Map.put(review, "requirements", List.duplicate(requirement, 12))
    assert {:ok, ^review} = Prompt.parse(Jason.encode!(review))
  end

  test "malformed reviewer output never becomes approval", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    {:ok, api} = FakeWorkCoopAPI.start_link(["Unstructured completion claim."], review_only: true)
    settings = Map.merge(settings, %{api: FakeWorkCoopAPI, client: api})

    assert CompletionReview.review(claim, final(candidate), settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    assert Repo.get!(Turn, claim.turn.id).validation_intent == nil
    [run] = Repo.all(Run)
    assert run.status == :rejected
    assert run.result == "Unstructured completion claim."

    stopped =
      Enum.reduce_while(1..3, nil, fn _, _ ->
        case CompletionReview.cancel(claim, settings) do
          :ok -> {:halt, :ok}
          pending -> {:cont, pending}
        end
      end)

    assert stopped == :ok
    assert Repo.get!(Run, run.id).remote_stopped_at
  end

  test "the evaluation client accepts only the exact narrowed review job", %{
    claim: claim,
    candidate: candidate,
    settings: settings
  } do
    {:ok, template} = Ryker.Evals.Job.new(:world, "codex:fixture/low@eval")
    {:ok, job, digest} = Ryker.Evals.Job.bind(template, claim.session.external_ref)

    session =
      claim.session
      |> Ecto.Changeset.change(
        policy: template.name,
        policy_digest: template.digest,
        worker_job_document: job,
        worker_job_digest: digest
      )
      |> Repo.update!()

    claim = %{claim | session: session}

    assert CompletionReview.review(claim, final(candidate), settings) ==
             {:error, {:work_poll_window_elapsed, :completion_review}}

    [run] = Repo.all(Run)
    task = FleetSession.external_ref(run)
    key = "ryker:completion-review:create:#{run.id}"

    client = %Ryker.Coop.Client{
      finch: Ryker.Finch,
      receive_timeout: 100,
      socket: "/tmp/unused-review-eval.sock",
      job: template
    }

    assert Ryker.Coop.Client.prepare_create_session(client, key, template.name, task, nil) == :ok

    assert Ryker.Coop.Client.prepare_create_session(client, key, template.name, "wrong-task", nil) ==
             {:error, :model_eval_session_authority_mismatch}
  end
end
