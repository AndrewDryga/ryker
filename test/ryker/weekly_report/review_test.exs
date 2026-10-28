defmodule Ryker.WeeklyReport.ReviewTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.Accounting.Execution
  alias Ryker.{Crypto, Repo, RoutingExamples, Settings, WeeklyReport}
  alias Ryker.Fixtures.Answers
  alias Ryker.Retention.Cleanup
  alias Ryker.Slack.ChannelMembership
  alias Ryker.TestSupport.FakeCoopAPI
  alias Ryker.WeeklyReport.{Custody, Report, Review, ReviewCustody, ReviewExecutor}
  alias Ryker.WeeklyReport.{ReviewFleetSession, ReviewPrompt}
  alias Ryker.Work.Session

  @actor "control-plane:local"
  @workspace "TWEEKLYREVIEW"
  @destination "slack:TWEEKLYREVIEW:CREPORT"
  # Public readiness answer supplied in the October 27 observation-card report,
  # with the customer name removed. Only the published words enter this review.
  @answer "Both application endpoints pass readiness; both VMs are in us-central1-a."

  defmodule API do
    alias Ryker.TestSupport.FakeCoopAPI, as: Fake
    defdelegate prepare_create_session(client, key, policy, ref, source), to: Fake
    defdelegate create_session(client, key, policy, ref, source), to: Fake
    defdelegate cancel_turn(client, session, turn, key, revision), to: Fake
    defdelegate get_turn(client, session, turn), to: Fake
    defdelegate get_session(client, session), to: Fake
    defdelegate operation_by_key(client, key), to: Fake

    def submit_frozen_turn(client, session, key, revision, submission, nil, []) do
      Fake.submit_turn(
        client,
        session,
        key,
        revision,
        submission["prompt"],
        submission["output_schema"]
      )
    end

    def validate_frozen_candidate(client, session, turn, key, _attempt, digest, verdict),
      do: Fake.validate_candidate(client, session, turn, key, digest, verdict)
  end

  setup do
    {:ok, settings} = Settings.initialize(@actor)

    {:ok, settings} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: @workspace,
          workspace_url: "https://weekly-review.slack.com",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          operators: ["U1111111111"]
        },
        settings.installation.revision,
        @actor
      )

    now = Repo.now!()

    Repo.insert!(%ChannelMembership{
      workspace_ref: @workspace,
      channel_ref: "CREPORT",
      status: :joined,
      generation: 1,
      joined_at: now,
      private: false,
      external_shared: false
    })

    period = %{
      week: %{from: DateTime.add(now, -7, :day), to: DateTime.add(now, 1), timezone: "Etc/UTC"},
      conversation_ref: @destination,
      saved_at: DateTime.add(now, -8, :day),
      deadline_at: DateTime.add(now, 300)
    }

    {:ok, _} =
      Settings.save_report(
        %{
          weekly_self_report_enabled: true,
          channel_ref: "CREPORT",
          weekday: 1,
          local_time: ~T[09:00:00],
          timezone: "Etc/UTC"
        },
        settings.installation.revision,
        @actor
      )

    Repo.update_all(Settings.Report, set: [saved_at: period.saved_at])
    %{now: now, period: period}
  end

  test "the review freezes only delivered public answers and keeps its identity on duplicate ticks",
       %{now: now, period: period} do
    public = answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    answer!("CPRIVATE", true, false, "PRIVATE SOURCE MUST NOT ENTER", now, "1793100010.000100")
    answer!("CSHARED", false, true, "SHARED SOURCE MUST NOT ENTER", now, "1793100020.000100")
    settings = settings(nil)
    assert {:ok, review} = ReviewCustody.prepare(period, settings)
    assert [%{"id" => id, "text" => @answer, "url" => url}] = review.manifest["evidence"]
    assert id == public.turn.id
    assert url =~ "https://weekly-review.slack.com/archives/CPUBLIC/"
    refute review.prompt =~ "PRIVATE SOURCE"
    refute review.prompt =~ "SHARED SOURCE"
    assert public.turn.id in review.source_turn_ids
    assert review.message_keys != []

    answer!("CLATER", false, false, "Later evidence", now, "1793100030.000100")
    assert {:ok, again} = ReviewCustody.prepare(period, settings)
    assert {again.id, again.prompt, again.manifest} == {review.id, review.prompt, review.manifest}
    assert Repo.aggregate(Review, :count) == 1
  end

  test "one asynchronous review survives lost submit acknowledgement and accounts for its own turn",
       %{now: now, period: period} do
    source = answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    result = recommendation(source.turn.id)

    {:ok, coop} =
      FakeCoopAPI.start_link([Jason.encode!(result)],
        async_create: true,
        async_submit: true,
        async_operations_running: true,
        fail_first_turn_response: true
      )

    settings = settings(coop)
    {:ok, _review} = ReviewCustody.prepare(period, settings)
    {:ok, claim} = ReviewCustody.claim("review-test", 300)
    {:ok, review} = ReviewCustody.begin_execution(claim)
    {:ok, session} = ReviewFleetSession.ensure(review)

    results = steps(claim, review, settings)
    assert Enum.any?(results, &match?({:ok, {:applied, _}}, &1))
    saved = ReviewCustody.current(review.id)
    assert saved.recommendations == result["recommendations"]
    assert saved.status == :applied
    assert saved.remote_stopped_at != nil
    assert length(FakeCoopAPI.state(coop).create_keys) == 1
    assert length(FakeCoopAPI.state(coop).turn_keys) == 1

    assert Repo.exists?(
             from(e in Execution, where: e.kind == "weekly_review" and e.source_id == ^review.id)
           )

    assert Repo.exists?(Cleanup.Query.eligible(Repo.now!()) |> Session.Query.by_id(session.id))
    assert ReviewCustody.claim("rival", 300) == {:ok, :idle}
  end

  test "an invalid recommendation stops the only turn rather than starting a repair loop", %{
    now: now,
    period: period
  } do
    answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    {:ok, coop} = FakeCoopAPI.start_link([Jason.encode!(recommendation(Repo.generate_id()))])
    settings = settings(coop)
    {:ok, _review} = ReviewCustody.prepare(period, settings)
    {:ok, claim} = ReviewCustody.claim("review-test", 300)
    {:ok, review} = ReviewCustody.begin_execution(claim)
    {:ok, _session} = ReviewFleetSession.ensure(review)
    assert {:ok, :stopped} in steps(claim, review, settings)
    assert ReviewCustody.current(review.id).status == :rejected
    assert length(FakeCoopAPI.state(coop).turn_keys) == 1
    assert ReviewCustody.claim("rival", 300) == {:ok, :idle}
  end

  test "forgetting a source erases copied recommendations and prevents a queued report from posting them",
       %{now: now, period: period} do
    source = answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    review = applied_review!(period, source.turn.id)

    {:ok, report} =
      Custody.enqueue(%{
        week: Date.beginning_of_week(DateTime.to_date(now)),
        due_at: now,
        period_start: period.week.from,
        timezone: "Etc/UTC",
        conversation_ref: @destination,
        message: "Private derived recommendation",
        review_id: review.id
      })

    assert {:ok, _request} = Custody.request(report)

    key =
      RoutingExamples.message_key(
        source.turn.external_receipt["conversation_ref"],
        source.turn.external_receipt["message_ref"]
      )

    assert Repo.transaction(fn ->
             :ok = RoutingExamples.exclusive_copy_lock_in_transaction()
             WeeklyReport.forget_in_transaction([], [key])
           end) == {:ok, :ok}

    erased = ReviewCustody.current(review.id)
    assert erased.prompt == nil
    assert erased.result == nil
    assert erased.manifest == nil
    assert erased.recommendations == []
    assert erased.forgotten_at != nil
    assert Custody.request(report) == {:error, :weekly_review_source_revoked}
    redacted = Repo.get!(Report, report.id)
    refute redacted.document["message"] =~ "Private derived"
    assert redacted.review_redacted_at != nil
  end

  test "an audience change revokes publication even if the report was queued earlier", %{
    now: now,
    period: period
  } do
    source = answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    review = applied_review!(period, source.turn.id)
    assert ReviewCustody.delivery_allowed?(review.id)

    Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "CPUBLIC"),
      set: [private: true]
    )

    refute ReviewCustody.delivery_allowed?(review.id)
  end

  test "a preview reads saved results without preparing or starting a review", %{period: period} do
    WeeklyReport.compose(period.week)
    assert Repo.aggregate(Review, :count) == 0

    assert Repo.aggregate(from(s in Session, where: s.execution_kind == :weekly_review), :count) ==
             0
  end

  test "the host rejects unknown evidence, duplicate problems and extra output fields" do
    id = Repo.generate_id()
    manifest = %{"evidence" => [%{"id" => id}], "known_decisions" => []}
    valid = recommendation(id)
    assert {:ok, _items} = ReviewPrompt.parse(Jason.encode!(valid), manifest)

    assert ReviewPrompt.parse(Jason.encode!(recommendation("unlisted")), manifest) ==
             {:error, :invalid_weekly_review_result}

    duplicate =
      Map.put(valid, "recommendations", valid["recommendations"] ++ valid["recommendations"])

    assert ReviewPrompt.parse(Jason.encode!(duplicate), manifest) ==
             {:error, :invalid_weekly_review_result}

    assert ReviewPrompt.parse(Jason.encode!(Map.put(valid, "extra", true)), manifest) ==
             {:error, :invalid_weekly_review_result}
  end

  # A deleted bot answer is still a delivered Work row; without checking its own
  # message identity the next weekly review would restore those deleted words.
  test "an answer deleted before preparation is never copied", %{now: now, period: period} do
    source = answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")

    Answers.slack_message!(
      workspace: @workspace,
      channel: "CPUBLIC",
      ts: source.turn.external_receipt["message_ref"],
      kind: :delete,
      text: "",
      revision: 2
    )

    assert {:ok, review} = ReviewCustody.prepare(period, settings(nil))
    assert review.manifest["evidence"] == []
    refute review.prompt =~ @answer
  end

  test "internal evidence cannot be published to an unknown or externally shared destination", %{
    now: now,
    period: period
  } do
    source = answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    review = applied_review!(period, source.turn.id)

    Repo.update_all(from(m in ChannelMembership, where: m.channel_ref == "CREPORT"),
      set: [external_shared: true]
    )

    refute ReviewCustody.delivery_allowed?(review.id)
    Repo.delete_all(from(m in ChannelMembership, where: m.channel_ref == "CREPORT"))
    refute ReviewCustody.delivery_allowed?(review.id)
  end

  test "revocation after submission is frozen prevents the remote effect", %{
    now: now,
    period: period
  } do
    source = answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    {:ok, _} = ReviewCustody.prepare(period, settings(nil))
    {:ok, claim} = ReviewCustody.claim("review-test", 300)
    {:ok, review} = ReviewCustody.begin_execution(claim)
    {:ok, frozen} = ReviewCustody.freeze_submit(claim, review.id, 1)

    key =
      RoutingExamples.message_key(
        source.turn.external_receipt["conversation_ref"],
        source.turn.external_receipt["message_ref"]
      )

    Repo.transaction(fn ->
      RoutingExamples.exclusive_copy_lock_in_transaction()
      WeeklyReport.forget_in_transaction([], [key])
    end)

    assert ReviewCustody.with_submission(frozen, settings(nil), fn ->
             flunk("forgotten prompt submitted")
           end) == {:error, :weekly_review_source_revoked}

    assert ReviewCustody.current(review.id).submit_revision == 1
  end

  test "disabling reports after a start prevents submission without losing custody", %{
    now: now,
    period: period
  } do
    answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    {:ok, _} = ReviewCustody.prepare(period, settings(nil))
    {:ok, claim} = ReviewCustody.claim("review-test", 300)
    {:ok, review} = ReviewCustody.begin_execution(claim)
    {:ok, frozen} = ReviewCustody.freeze_submit(claim, review.id, 1)
    Repo.update_all(Settings.Report, set: [weekly_self_report_enabled: false])

    assert ReviewCustody.with_submission(frozen, settings(nil), fn ->
             flunk("disabled review submitted")
           end) == {:error, :weekly_review_source_revoked}

    assert ReviewCustody.current(review.id).remote_stopped_at == nil
  end

  test "a delayed enqueue refuses a recommendation whose source was forgotten", %{
    now: now,
    period: period
  } do
    source = answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    review = applied_review!(period, source.turn.id)

    Repo.transaction(fn ->
      WeeklyReport.forget_conversation_in_transaction("slack:" <> @workspace <> ":CPUBLIC")
    end)

    assert Custody.enqueue(%{
             week: Date.beginning_of_week(DateTime.to_date(now)),
             due_at: now,
             period_start: period.week.from,
             timezone: "Etc/UTC",
             conversation_ref: @destination,
             message: "stale recommendation",
             review_id: review.id
           }) == {:error, :weekly_review_source_revoked}

    assert Repo.aggregate(Report, :count) == 0
  end

  test "source retention erases copied review and queued report while preserving remote receipts",
       %{now: now, period: period} do
    source = answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    review = applied_review!(period, source.turn.id)

    {:ok, report} =
      Custody.enqueue(%{
        week: Date.beginning_of_week(DateTime.to_date(now)),
        due_at: now,
        period_start: period.week.from,
        timezone: "Etc/UTC",
        conversation_ref: @destination,
        message: "expired recommendation",
        review_id: review.id
      })

    Repo.update_all(from(t in Ryker.Work.Turn, where: t.id == ^source.turn.id),
      set: [operational_pruned_at: now]
    )

    retention = %{
      audit_data_seconds: 60,
      closed_work_seconds: 60,
      conversation_memory_seconds: 60,
      episode_history_seconds: 60,
      operational_data_seconds: 60,
      routing_examples_enabled: false,
      routing_examples_seconds: 86_400,
      work_examples_enabled: false,
      work_examples_seconds: 86_400
    }

    assert {:ok, _} = Ryker.Retention.Data.prune(retention)
    pruned = ReviewCustody.current(review.id)
    assert pruned.pruned_at
    assert pruned.prompt == nil
    assert pruned.recommendations == []
    assert pruned.stop_receipt == review.stop_receipt
    assert Repo.get!(Report, report.id).review_redacted_at
    refute Repo.get!(Report, report.id).document["message"] =~ "expired recommendation"
  end

  test "disabled review worker settles an unsubmitted start without any provider call", %{
    now: now,
    period: period
  } do
    answer!("CPUBLIC", false, false, @answer, now, "1793100000.000100")
    {:ok, coop} = FakeCoopAPI.start_link([])
    settings = settings(coop)
    {:ok, review} = ReviewCustody.prepare(period, settings)
    {:ok, claim} = ReviewCustody.claim("review-test", 300)
    {:ok, _review} = ReviewCustody.begin_execution(claim)
    {:ok, _review} = ReviewCustody.release(claim, 0)
    assert {:ok, _} = Ryker.WeeklyReport.ReviewWorker.run_once(%{settings | enabled: false})
    saved = ReviewCustody.current(review.id)
    assert saved.remote_stopped_at
    assert saved.error_code == "weekly_review_disabled"
    assert FakeCoopAPI.state(coop).turn_keys == []
  end

  defp applied_review!(period, source_id) do
    {:ok, review} = ReviewCustody.prepare(period, settings(nil))
    result = recommendation(source_id)

    review
    |> Ecto.Changeset.change(
      status: :applied,
      result: Jason.encode!(result),
      result_sha256: Crypto.sha256_hex(Jason.encode!(result)),
      recommendations: result["recommendations"],
      validation_receipt: %{"receipt" => "test"},
      remote_stopped_at: Repo.now!(),
      stop_receipt: %{"kind" => "terminal_turn"}
    )
    |> Repo.update!()
  end

  defp answer!(channel, private, shared, text, now, ts) do
    Repo.insert!(%ChannelMembership{
      workspace_ref: @workspace,
      channel_ref: channel,
      status: :joined,
      generation: 1,
      joined_at: now,
      private: private,
      external_shared: shared
    })

    entry =
      Answers.slack_message!(
        workspace: @workspace,
        channel: channel,
        ts: ts,
        text: "Check infrastructure health"
      )

    Answers.work_reply!(entry, text, String.replace(ts, "000100", "000200"), now)
  end

  defp recommendation(id),
    do: %{
      "recommendations" => [
        %{
          "problem_key" => "application-zone-diversity",
          "action" => "Review application zone diversity",
          "benefit" => "Reduce the shared zone-failure risk.",
          "evidence_ids" => [id]
        }
      ]
    }

  defp settings(coop),
    do: %{
      api: API,
      client: coop,
      policy: "ryker-weekly-review",
      policy_digest: String.duplicate("a", 64),
      worker_ref: "weekly-review-test",
      enabled: true,
      poll_interval_ms: 100,
      lease_seconds: 300,
      execution_timeout_seconds: 300
    }

  defp steps(claim, review, settings) do
    Enum.reduce_while(1..30, [], fn _, results ->
      result = ReviewExecutor.step(claim, review, settings)

      if match?({:ok, {:applied, _}}, result) or result == {:ok, :stopped},
        do: {:halt, results ++ [result]},
        else: {:cont, results ++ [result]}
    end)
  end
end
