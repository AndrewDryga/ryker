defmodule Ryker.Work.ExecutorInstallationTest do
  # The Work executor's tests that change installation-wide state: a saved
  # setting, which the one installation row holds, and the global
  # instructions, which one lock fences. Either holds its row or its lock for
  # the whole sandboxed test, so these run serially, and the executor's
  # other tests run async (executor_test.exs, since 2026-10-14).
  use Ryker.DataCase, async: false
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkerJob
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.TestSupport.FakeWorkCoopAPI, as: FakeAPI
  alias Ryker.Work.{Activity, Custody, Executor, Final, Session}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "one frozen turn reaches a validated durable delivery intent" do
    assert {:ok, _} =
             Ryker.Instructions.save(:global, "Explain the evidence.", 0, "operator:test")

    claim = claim_episode!("valid")
    session_id = "remote_work_#{System.unique_integer([:positive])}"

    activity = [
      %{
        "id" => "event:valid:1",
        "occurred_at" => DateTime.to_iso8601(@now),
        "payload" => %{"text" => "Checking the requested evidence."},
        "sequence" => 1,
        "session_id" => session_id,
        "turn_id" => "work_turn_#{session_id}_1",
        "type" => "model.thought",
        "version" => 1
      }
    ]

    {:ok, fake} =
      FakeAPI.start_link([reply("Investigation complete.")],
        activity_events: activity,
        session_id: session_id
      )

    assert {:ok, execution} = Executor.run(claim, options(fake))
    assert execution.status == :accepted
    assert execution.turn.status == :delivery_pending
    assert execution.episode.owner_kind == :delivery

    state = FakeAPI.state(fake)

    assert Jason.decode!(hd(state.submissions).prompt)["work"]["custom_instructions"]["global"][
             "text"
           ] == "Explain the evidence."

    assert state.create_count == 1
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:accept]
    assert state.submissions |> hd() |> Map.fetch!(:schema) == Final.json_schema()
    refute state.submissions |> hd() |> Map.fetch!(:prompt) =~ ~s("$schema")
    assert [{^session_id, 0, 1_000} | _rest] = state.activity_requests

    assert [%{kind: "model.thought"}] = Activity.page_for_episode(claim.episode.id).events
  end

  test "changing model settings does not rotate a running immutable job" do
    claim = claim_with_bound_empty_session!("model-setting-frozen", String.duplicate("f", 64))
    {:ok, fake} = fake_for(claim, [reply("The frozen model answered.")])
    saved = Repo.reload!(claim.session)
    {:ok, snapshot} = Settings.initialize("control-plane:local")

    assert {:ok, _} =
             Settings.save_work(
               %{conversation_models: ["codex:gpt-5.6-terra/high@default"]},
               snapshot.installation.revision,
               "control-plane:local"
             )

    assert {:ok, %{status: :accepted}} = Executor.run(claim, options(fake))
    assert Repo.get!(Ryker.Work.Turn, claim.turn.id).session_id == claim.session.id
    assert Repo.reload!(claim.session).worker_job_document == saved.worker_job_document
    assert FakeAPI.state(fake).create_count == 0
  end

  defp claim_episode!(suffix), do: claim_episode!(suffix, nil, :live, nil)

  defp claim_episode!(suffix, payload, execution_mode, authority_digest) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        actor_ref: "slack:user:U-stage3",
        episode_id: id,
        episode_key: "work-executor:#{suffix}:#{id}",
        execution_mode: execution_mode,
        native_input_id: "slack-message:#{suffix}:#{id}",
        occurred_at: @now,
        payload: payload || %{"text" => "Please handle #{suffix}."},
        turn_ref: "turn:#{suffix}:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             WorkSessions.pin_episode(id, "work-read-only", String.duplicate("a", 64),
               authority_digest: authority_digest
             )

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}", 60, :work)
    claim
  end

  defp claim_with_bound_empty_session!(suffix, authority_digest) do
    claim = claim_episode!(suffix, nil, :live, authority_digest)

    assert {:ok, session} =
             Custody.bind_session(
               claim.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "remote:#{claim.episode.id}"
             )

    %{claim | session: session}
  end

  defp options(fake) do
    [
      api: FakeAPI,
      client: fake,
      lease_seconds: 60,
      max_block_ms: 1_000,
      max_polls: 20,
      monotonic_ms: fn -> 0 end,
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  defp fake_for(claim, candidates) do
    pinned = claim.session |> Repo.reload!() |> WorkerJob.pin!()

    with {:ok, fake} <- FakeAPI.start_link(candidates) do
      FakeAPI.update(fake, fn state ->
        session =
          Map.merge(state.session, %{
            "external_ref" => Session.coop_task_ref(claim.session),
            "id" => claim.session.coop_session_id || "remote:#{claim.episode.id}",
            "job_ref" => claim.session.external_ref,
            "job_digest" => pinned.worker_job_digest
          })

        %{state | session: session}
      end)

      {:ok, fake}
    end
  end

  defp reply(message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{"artifact_refs" => [], "record_refs" => [], "state" => "complete"}
    })
  end
end
