defmodule Ryker.WeeklyReport.ReviewConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{CanonicalJSON, Crypto, Repo, Retention, Settings, WeeklyReport}
  alias Ryker.CoopFleet.{Bodies, Bridge, Command, ControlPlane, Placement}
  alias Ryker.Fixtures.{CoopWorkers, WorkerJob}
  alias Ryker.Slack.ChannelMembership
  alias Ryker.WeeklyReport.{Custody, Report, Review, ReviewCustody, ReviewFleetSession}
  alias Ryker.Work.Session

  @destination "slack:TWEEKLYRACE:CWEEKLYRACE"
  @words "Review application zone diversity"

  # The review copies published answers. Revocation between rendering and insertion
  # must not restore those words in a report that did not exist when erasure began.
  test "forgetting concurrent with report composition erases the newly queued copy" do
    Sandbox.unboxed_run(Repo, fn ->
      review = review!()
      parent = self()

      copier =
        unboxed_task(fn ->
          ReviewCustody.with_evidence(fn ->
            saved = ReviewCustody.current_for_copy(review.id)
            send(parent, {:copying, backend_pid()})
            receive do: (:continue -> enqueue(saved))
          end)
        end)

      assert_receive {:copying, copying_backend}, 5_000

      deleter =
        unboxed_task(fn ->
          send(parent, {:deleting, backend_pid()})

          Repo.transaction(fn ->
            WeeklyReport.forget_conversation_in_transaction(@destination)
          end)
        end)

      assert_receive {:deleting, deleting_backend}, 5_000

      try do
        assert :waiting == await_finished_or_blocked(deleter, deleting_backend, copying_backend)
        send(copier.pid, :continue)
        assert {:ok, report} = Task.await(copier, 5_000)
        assert Task.await(deleter, 5_000) == {:ok, :ok}
        assert Repo.get!(Report, report.id).review_redacted_at
        refute Repo.get!(Report, report.id).document["message"] =~ @words
        assert Custody.request(report) == {:error, :weekly_review_source_revoked}
      after
        stop_tasks([copier, deleter])
        clean!(review)
      end
    end)
  end

  test "retention waits for a report copy and erases it on its next pass" do
    Sandbox.unboxed_run(Repo, fn ->
      review = review!()
      parent = self()

      copier =
        unboxed_task(fn ->
          ReviewCustody.with_evidence(fn ->
            saved = ReviewCustody.current_for_copy(review.id)
            send(parent, :copying)
            receive do: (:continue -> enqueue(saved))
          end)
        end)

      assert_receive :copying, 5_000

      try do
        assert {:ok, _} = Retention.Data.prune(retention())
        assert Repo.get!(Review, review.id).prompt == @words
        send(copier.pid, :continue)
        assert {:ok, report} = Task.await(copier, 5_000)
        assert {:ok, _} = Retention.Data.prune(retention())
        assert Repo.get!(Review, review.id).prompt == nil
        assert Repo.get!(Report, report.id).review_redacted_at
        refute Repo.get!(Report, report.id).document["message"] =~ @words
      after
        stop_tasks([copier])
        clean!(review)
      end
    end)
  end

  # Waiting under the copying transaction hid the first command from the
  # outbound worker until timeout. A sandbox-shared fake API could not catch it.
  test "the worker receives a fenced submission before the submit caller finishes waiting" do
    with_fleet(fn _review, session, worker ->
      assert {:ok, %{}} = bridge_command(session, worker, "submit_turn", submission(session))
    end)
  end

  test "forgetting after enqueue prevents the worker from receiving the copied prompt" do
    with_fleet(fn review, session, worker ->
      command = enqueue_command(session, "submit_turn", submission(session))

      assert Repo.transaction(fn ->
               WeeklyReport.forget_conversation_in_transaction(@destination)
             end) == {:ok, :ok}

      assert {:ok, %{"commands" => []}} =
               ControlPlane.handle_poll_certificate(worker, poll(worker, []))

      erased = Repo.get!(Command, command.id)
      assert erased.error["code"] == "operation_not_enqueued"
      assert erased.status == :failed
      assert erased.delivered_at == nil
      assert erased.payload_fingerprint == command.payload_fingerprint
      refute Jason.encode!(erased.payload) =~ @words
      assert Repo.get!(Review, review.id).forgotten_at
    end)
  end

  for reason <- [:deadline, :disabled] do
    @reason reason
    test "a queued review cannot start after #{@reason}" do
      with_fleet(fn review, session, worker ->
        command = enqueue_command(session, "submit_turn", submission(session))

        case @reason do
          :deadline ->
            review
            |> Ecto.Changeset.change(deadline_at: DateTime.add(Repo.now!(), -1))
            |> Repo.update!()

          :disabled ->
            Repo.update_all(Settings.Report, set: [weekly_self_report_enabled: false])
        end

        assert {:ok, %{"commands" => []}} =
                 ControlPlane.handle_poll_certificate(worker, poll(worker, []))

        saved = Repo.get!(Command, command.id)
        assert saved.status == :failed
        assert saved.error["code"] == "operation_not_enqueued"
        assert saved.delivered_at == nil
      end)
    end
  end

  test "source expiry fences queued prompts and scrubs completed transport copies in the same pass" do
    with_fleet(fn review, session, _worker ->
      queued = enqueue_command(session, "submit_turn", submission(session))

      completed =
        enqueue_command(session, "get_turn", %{
          "coop_session_id" => session.coop_session_id,
          "coop_turn_id" => "turn-one"
        })

      completed
      |> Ecto.Changeset.change(
        status: :succeeded,
        result: %{"status" => 200, "body" => %{"candidate" => %{"message" => @words}}},
        operation_key: completed.idempotency_key,
        result_fingerprint: String.duplicate("a", 64),
        completed_at: Repo.now!()
      )
      |> Repo.update!()

      review
      |> Ecto.Changeset.change(
        status: :stale,
        remote_stopped_at: Repo.now!(),
        stop_receipt: %{"kind" => "terminal_turn", "state" => "completed"}
      )
      |> Repo.update!()

      assert {:ok, _} = Retention.Data.prune(retention())
      saved = Repo.get!(Command, queued.id)
      assert saved.status == :failed
      assert saved.error["code"] == "operation_not_enqueued"
      refute Jason.encode!(saved.payload) =~ @words
      refute Jason.encode!(Repo.get!(Command, completed.id).result) =~ @words
    end)
  end

  for mode <- [:inline, :file] do
    @mode mode
    test "a late #{@mode} answer is erased after stop while exact worker replays still ACK" do
      with_fleet(fn review, session, worker ->
        command =
          enqueue_command(session, "get_turn", %{
            "coop_session_id" => session.coop_session_id,
            "coop_turn_id" => "turn-one"
          })

        assert {:ok, %{"commands" => [_]}} =
                 ControlPlane.handle_poll_certificate(worker, poll(worker, []))

        root = Path.join(System.tmp_dir!(), "weekly-revoked-" <> Repo.generate_id())

        bytes =
          Jason.encode!(%{
            "id" => "turn-one",
            "state" => "completed",
            "candidate" => %{"message" => @words}
          })

        reference = %{"byte_size" => byte_size(bytes), "sha256" => Crypto.sha256_hex(bytes)}

        try do
          # A worker may have uploaded just before the source was revoked.
          if @mode == :file do
            assert Bodies.put(
                     root,
                     command.id,
                     :response,
                     reference,
                     [bytes],
                     Ryker.Secret.new(:binary.copy(<<7>>, 32))
                   ) == :ok
          end

          review
          |> Ecto.Changeset.change(
            status: :stale,
            remote_stopped_at: Repo.now!(),
            stop_receipt: %{"kind" => "terminal_turn", "state" => "completed"}
          )
          |> Repo.update!()

          assert Repo.transaction(fn ->
                   WeeklyReport.forget_conversation_in_transaction(@destination)
                 end) == {:ok, :ok}

          if @mode == :file do
            assert Bodies.prune_orphans(root) == :ok
            assert File.exists?(Path.join(root, command.id))
          end

          resource =
            if @mode == :file,
              do: %{"status" => 200, "body_ref" => reference},
              else: %{"status" => 200, "body" => Jason.decode!(bytes)}

          result = %{
            "command_id" => command.id,
            "error" => nil,
            "operation_key" => command.idempotency_key,
            "resource" => resource,
            "state" => "succeeded"
          }

          for _replay <- 1..2 do
            assert {:ok, response} =
                     ControlPlane.handle_poll_certificate(worker, poll(worker, [result]),
                       body_root: root
                     )

            assert response["acknowledged_result_command_ids"] == [command.id]
          end

          saved = Repo.get!(Command, command.id)
          assert saved.result_fingerprint == CanonicalJSON.digest(result)
          refute Jason.encode!(saved.result) =~ @words
          refute Map.has_key?(saved.result, "body_ref")
          refute File.exists?(Path.join(root, command.id))
        after
          File.rm_rf!(root)
        end
      end)
    end
  end

  defp with_fleet(callback) do
    Sandbox.unboxed_run(Repo, fn ->
      review =
        review!()
        |> Ecto.Changeset.change(
          status: :prepared,
          remote_stopped_at: nil,
          stop_receipt: nil,
          validation_receipt: nil,
          deadline_at: DateTime.add(Repo.now!(), 300)
        )
        |> Repo.update!()

      Repo.insert!(%Settings.Installation{
        host_ref: "weekly-test",
        revision: 1,
        saved_by: "control-plane:local",
        saved_at: Repo.now!(),
        inserted_at: Repo.now!()
      })

      Repo.insert!(%Settings.Report{
        id: "weekly-test",
        weekly_self_report_enabled: true,
        channel_ref: "CWEEKLYRACE"
      })

      Repo.insert!(%Settings.Slack{
        id: "weekly-test",
        enabled: true,
        workspace_ref: "TWEEKLYRACE",
        workspace_url: "https://weekly-test.slack.com",
        bot_ref: "A0123456789",
        bot_user_ref: "U0123456789"
      })

      worker = "weekly-enqueue-race"
      {:ok, _} = CoopWorkers.authorize(worker, "workspace-main", Crypto.sha256_hex(worker))
      {:ok, _} = ControlPlane.handle_poll_certificate(worker, poll(worker, []))
      {:ok, session} = ReviewFleetSession.ensure(review)
      session = WorkerJob.pin!(session)

      try do
        create = %{
          "external_ref" => session.external_ref,
          "job" => session.worker_job_document,
          "job_digest" => session.worker_job_digest
        }

        assert {:ok, %{}} = bridge_command(session, worker, "create_session", create)
        {:ok, session} = ReviewFleetSession.bind(review, "weekly-remote")
        callback.(review, session, worker)
      after
        Repo.delete_all(Command.Query.by_session_id(session.id))
        Repo.delete_all(Placement.Query.by_session_id(session.id))
        Repo.delete_all(Session.Query.by_id(session.id))
        Repo.delete_all(from(c in Ryker.CoopFleet.Certificate, where: c.worker_id == ^worker))
        Repo.delete_all(from(w in Ryker.CoopFleet.Worker, where: w.id == ^worker))
        Repo.delete_all(from(r in Settings.Report, where: r.id == "weekly-test"))
        Repo.delete_all(from(s in Settings.Slack, where: s.id == "weekly-test"))
        Repo.delete_all(from(i in Settings.Installation, where: i.host_ref == "weekly-test"))
        clean!(review)
      end
    end)
  end

  defp enqueue_command(session, kind, payload) do
    placement = Repo.one!(Placement.Query.by_session_id(session.id))

    {:ok, command} =
      ControlPlane.enqueue_command(
        placement.id,
        kind,
        payload,
        "weekly-test:" <> Repo.generate_id()
      )

    command
  end

  defp submission(session) do
    %{
      "coop_session_id" => session.coop_session_id,
      "expected_revision" => 1,
      "submission" => %{
        "contract_version" => "weekly-review-v1",
        "input_artifact_refs" => [],
        "prompt" => @words,
        "output_schema" => %{"type" => "object"}
      }
    }
  end

  defp bridge_command(session, worker, kind, payload) do
    key = "weekly-test:" <> Repo.generate_id()

    Bridge.execute(session, kind, payload, key,
      workspace_ref: "workspace-main",
      max_waits: 1,
      poll_interval_ms: 1,
      enqueue_guard: fn _kind, enqueue -> ReviewCustody.with_evidence(enqueue) end,
      wait: fn ->
        worker_poll =
          unboxed_task(fn ->
            assert {:ok, %{"commands" => [command]}} =
                     ControlPlane.handle_poll_certificate(worker, poll(worker, []))

            assert command["idempotency_key"] == key

            result = %{
              "command_id" => command["command_id"],
              "error" => nil,
              "operation_key" => key,
              "resource" => %{"status" => 200, "body" => %{}},
              "state" => "succeeded"
            }

            assert {:ok, response} =
                     ControlPlane.handle_poll_certificate(worker, poll(worker, [result]))

            assert response["acknowledged_result_command_ids"] == [command["command_id"]]
          end)

        try do
          Task.await(worker_poll, 5_000)
          :ok
        after
          stop_tasks([worker_poll])
        end
      end
    )
  end

  defp poll(worker, results) do
    %{
      "acknowledged_command_ids" => [],
      "command_results" => results,
      "event_batches" => [],
      "poll_ref" => Repo.generate_id(),
      "version" => 2,
      "worker" => %{
        "build_version" => "coop-test",
        "capabilities" => [],
        "capacity" => %{
          "cooldown_until" => nil,
          "state" => "eligible",
          "session_slots_free" => 2,
          "session_slots_total" => 2,
          "turn_slots_free" => 2,
          "turn_slots_total" => 2,
          "workspace_slots_free" => 2,
          "workspace_slots_total" => 2
        },
        "clock_at" => DateTime.to_iso8601(Repo.now!()),
        "id" => worker,
        "protocol_version" => "2",
        "sandbox_digest" => String.duplicate("a", 64),
        "state" => "eligible",
        "workspace_ref" => "workspace-main"
      }
    }
  end

  defp review! do
    now = Repo.now!()

    Repo.insert!(%ChannelMembership{
      workspace_ref: "TWEEKLYRACE",
      channel_ref: "CWEEKLYRACE",
      status: :joined,
      generation: 1,
      joined_at: now,
      private: false,
      external_shared: false
    })

    Repo.insert!(%Review{
      identity: Crypto.sha256_hex(Repo.generate_id()),
      conversation_ref: @destination,
      period_start: ~U[2020-01-01 00:00:00.000000Z],
      period_end: ~U[2020-01-08 00:00:00.000000Z],
      deadline_at: ~U[2020-01-08 00:05:00.000000Z],
      timezone: "Etc/UTC",
      status: :applied,
      policy: "ryker-weekly-review",
      policy_digest: String.duplicate("a", 64),
      prompt: @words,
      prompt_sha256: Crypto.sha256_hex(@words),
      source_conversation_refs: [@destination],
      manifest: %{"evidence" => [%{"conversation_ref" => @destination}]},
      recommendations: [%{"action" => @words}],
      remote_stopped_at: now,
      validation_receipt: %{"receipt" => "test"},
      stop_receipt: %{"kind" => "terminal_turn"}
    })
  end

  defp enqueue(review) do
    now = Repo.now!()

    Custody.enqueue(%{
      week: Date.beginning_of_week(DateTime.to_date(now)),
      due_at: now,
      period_start: DateTime.add(now, -7, :day),
      timezone: "Etc/UTC",
      conversation_ref: @destination,
      message: review.prompt,
      review_id: review.id
    })
  end

  defp clean!(review) do
    Repo.delete_all(from(r in Report, where: r.review_id == ^review.id))
    Repo.delete_all(from(r in Review, where: r.id == ^review.id))
    Repo.delete_all(from(m in ChannelMembership, where: m.workspace_ref == "TWEEKLYRACE"))
  end

  defp retention do
    %{
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
  end
end
