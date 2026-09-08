defmodule Responder.State.LearningFailureTest do
  use Responder.DataCase, async: false
  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Learning.FleetSession
  alias Responder.Repo
  alias Responder.Slack.ChannelMembership

  alias Responder.State.{
    ConversationKnowledge,
    ConversationObservation,
    KnowledgeRevision,
    Learning,
    LearningRun,
    Observations
  }

  alias Responder.Work.Turn

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}
  @fixture "testdata/learning/retained-output-contract-failure.json"

  test "provider contract exhaustion supplies static feedback without renewing its spending budget" do
    # The retained batch371 provider failure had no public accepted result. A
    # fresh start needs the same contract correction as host rejection, not an
    # identical blind prompt; the three-start bound must still hold.
    ids = Enum.map(Fixtures.inputs!(), & &1.id)
    assert {:ok, first} = prepare_with_custody(ids, @policy)
    assert Jason.decode!(first.prompt)["previous_attempt_error"] == nil

    assert {:ok, failed} =
             Learning.fail(first.id, :output_contract_failed, failure_receipt(first))

    assert {:ok, second} = prepare_with_custody(ids, @policy)
    feedback = Jason.decode!(second.prompt)["previous_attempt_error"]
    assert feedback["code"] == "output_contract_failed"
    assert feedback["instruction"] =~ "required JSON shape"
    assert byte_size(second.prompt) <= 65_536
    assert second.batch_key == first.batch_key
    assert Repo.get!(LearningRun, first.id) == failed

    assert {:ok, _} = Learning.fail(second.id, :output_contract_failed, failure_receipt(second))

    assert {:ok, third} = prepare_with_custody(ids, @policy)
    assert {:ok, _} = Learning.fail(third.id, :output_contract_failed, failure_receipt(third))
    assert {:error, :learning_retry_exhausted} = prepare_with_custody(ids, @policy)
    assert Repo.aggregate(LearningRun, :count) == 3
  end

  test "host-rejected model results spend the same durable retry budget as provider failures" do
    # The replay exhausted contract attempts on batch 371. Counting only Coop's
    # terminal error lets the same unusable public result buy endless new host
    # generations instead. Use the unchanged recorded body, not a made-up answer.
    ids = Enum.map(Fixtures.inputs!(), & &1.id)
    body = hd(fixture()["public_responses"])["text"]

    for generation <- 1..3 do
      assert {:ok, run} = prepare_with_custody(ids, @policy)
      assert run.generation == generation

      assert {:error, :invalid_learning_result} =
               Responder.Fixtures.Learning.accept(run.id, body, %{})

      assert Repo.get!(LearningRun, run.id).status == :rejected
    end

    assert {:error, :learning_retry_exhausted} = prepare_with_custody(ids, @policy)
    assert Repo.aggregate(LearningRun, :count) == 3
    assert Repo.aggregate(ConversationKnowledge, :count) == 0
  end

  # Batch 371 exhausted Coop's three contract attempts, but stayed prepared and
  # wedged every restart. A fresh host generation must not reset an endless loop.
  test "three durable execution failures deny a fourth generation even after receipt pruning" do
    entries = Fixtures.inputs!()
    ids = Enum.map(entries, & &1.id)
    assert {:ok, run} = prepare_with_custody(ids, @policy)
    failures = seed_failures!(run, 3)

    assert {:error, :learning_retry_exhausted} = prepare_with_custody(ids, @policy)
    assert Repo.aggregate(LearningRun, :count) == 3

    expired = DateTime.add(DateTime.utc_now(), -3601) |> DateTime.to_iso8601()

    for failed <- failures do
      dependencies = Enum.map(failed.source_dependencies, &Map.put(&1, "retained_at", expired))
      Repo.update!(Ecto.Changeset.change(failed, source_dependencies: dependencies))
    end

    assert {:ok, 3} = Repo.transaction(fn -> Learning.prune_in_transaction(3600) end)
    assert {:error, :learning_retry_exhausted} = prepare_with_custody(ids, @policy)
    assert Repo.aggregate(LearningRun, :count) == 3

    for failed <- failures do
      saved = Repo.get!(LearningRun, failed.id)
      assert saved.status == :rejected
      assert saved.error_code == "output_contract_failed"
      assert saved.producer == %{}
      assert saved.pruned_at != nil
    end
  end

  test "the failure fixture retains every exact rejected public body rather than repairing it" do
    fixture = fixture()
    assert length(fixture["public_responses"]) == 3
    assert length(fixture["public_corrections"]) == 2

    for response <- fixture["public_responses"] do
      assert byte_size(response["text"]) == response["bytes"]
      assert sha256(response["text"]) == response["sha256"]
    end

    [first, second, third] = fixture["public_responses"]
    assert {:error, _} = Jason.decode(first["text"])
    assert second["text"] == third["text"]
    assert String.contains?(second["text"], "nqkx5fn4cw fkb6qx")
    assert fixture["learning_run"]["result"] == nil
    assert fixture["learning_run"]["result_sha256"] == nil
  end

  test "a terminal failure preserves its frozen input and public identity without creating knowledge" do
    run = retained_run!()
    before = protected_rows()
    receipt = failure_receipt(run)

    assert {:ok, failed} = Learning.fail(run.id, :output_contract_failed, receipt)
    assert failed.status == :rejected
    assert failed.error_code == "output_contract_failed"
    assert failed.producer == receipt
    assert failed.result == nil
    assert failed.result_sha256 == nil
    assert failed.remote_stopped_at != nil
    assert failed.stop_receipt["id"] == receipt["turn_id"]
    assert failed.stop_receipt["session_id"] == receipt["session_id"]
    assert failed.stop_receipt["failure"] == receipt
    assert frozen(failed) == frozen(run)
    assert protected_rows() == before
    assert {:ok, ^failed} = Learning.fail(run.id, :output_contract_failed, receipt)
    assert Repo.get!(LearningRun, run.id) == failed

    for response <- fixture()["public_responses"] do
      assert {:error, :learning_attempt_finished} =
               Responder.Fixtures.Learning.accept(run.id, response["text"], receipt)
    end

    assert Repo.get!(LearningRun, run.id) == failed
    assert protected_rows() == before
  end

  test "generic provider failure preserves a previously recorded candidate and its producer" do
    ids = Enum.map(Fixtures.inputs!(), & &1.id)
    assert {:ok, run} = prepare_with_custody(ids, @policy)
    receipt = failure_receipt(run)
    body = hd(fixture()["public_responses"])["text"]
    producer = %{"target" => "host-contract-test-provider"}

    candidate = %{
      "id" => receipt["turn_id"],
      "session_id" => receipt["session_id"],
      "candidate" => %{"message" => body, "sha256" => sha256(body), "attempt" => 1}
    }

    assert {:ok, saved} = Learning.record_candidate(run.id, candidate, producer)
    assert saved.status == :responded

    # Structural provider-failure variant: missing optional provider metadata
    # must not erase an already retained public candidate or invent timestamps.
    generic =
      Map.merge(receipt, %{
        "error_code" => "provider_unavailable",
        "target" => nil,
        "finished_at" => nil
      })

    assert {:ok, failed} = Learning.fail(run.id, :learning_provider_failed, generic)
    assert failed.status == :rejected
    assert failed.result == saved.result
    assert failed.result_sha256 == saved.result_sha256
    assert failed.producer == producer
    assert failed.stop_receipt["failure"] == generic
    assert failed.remote_stopped_at != nil
    assert {:ok, ^failed} = Learning.fail(run.id, :learning_provider_failed, generic)
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
  end

  test "a terminal receipt without its bound native session cannot record failure or stop proof" do
    run = retained_run!()
    receipt = failure_receipt(run)

    from(s in Responder.Work.Session, where: s.learning_run_id == ^run.id)
    |> Repo.update_all(set: [coop_session_id: nil])

    assert {:error, :invalid_learning_failure} =
             Learning.fail(run.id, :output_contract_failed, receipt)

    assert Repo.get!(LearningRun, run.id) == run
  end

  for field <- ~w(session_id turn_id target finished_at) do
    test "a conflicting #{field} cannot replace an immutable terminal receipt" do
      run = retained_run!()
      receipt = failure_receipt(run)
      assert {:ok, failed} = Learning.fail(run.id, :output_contract_failed, receipt)

      value =
        if unquote(field) == "finished_at",
          do: "2026-09-07T22:11:26.356692Z",
          else: "different-host-contract-identity"

      assert {:error, _} =
               Learning.fail(
                 run.id,
                 :output_contract_failed,
                 Map.put(receipt, unquote(field), value)
               )

      assert Repo.get!(LearningRun, run.id) == failed
    end
  end

  for {field, value} <- [
        {"session_id", ""},
        {"turn_id", nil},
        {"target", String.duplicate("x", 4097)},
        {"prompt_sha256", String.duplicate("f", 64)},
        {"state", "running"},
        {"error_code", "provider_unavailable"},
        {"finished_at", nil},
        {"finished_at", "now"},
        {"finished_at", "-infinity"},
        {"finished_at", "2026-09-07T22:11:25+01:00"},
        {"finished_at", "2026-09-07T22:11:25Z\nextra"}
      ] do
    test "invalid failure #{field}=#{inspect(value, limit: 1, printable_limit: 24)} leaves the run prepared" do
      run = retained_run!()
      receipt = Map.put(failure_receipt(run), unquote(field), unquote(value))
      assert {:error, _} = Learning.fail(run.id, :output_contract_failed, receipt)
      assert Repo.get!(LearningRun, run.id) == run
    end
  end

  test "unknown failure classes and malformed or oversized receipts cannot finish a run" do
    run = retained_run!()
    receipt = failure_receipt(run)
    assert {:error, _} = Learning.fail(run.id, :provider_unavailable, receipt)
    assert {:error, _} = Learning.fail(run.id, :output_contract_failed, nil)

    assert {:error, _} =
             Learning.fail(
               run.id,
               :output_contract_failed,
               Map.put(receipt, "extra", "unexpected")
             )

    assert {:error, _} = Learning.fail("not-a-uuid", :output_contract_failed, receipt)
    assert {:error, _} = Learning.fail(Ecto.UUID.generate(), :output_contract_failed, receipt)
    assert Repo.get!(LearningRun, run.id) == run
  end

  for status <- [:responded, :applied, :stale, :rejected] do
    test "an existing #{status} outcome cannot be converted to an execution failure" do
      run = retained_run!()
      # Host state fault injection using unchanged public bytes, not another
      # purported successful model answer or historical candidate reconstruction.
      body = hd(fixture()["public_responses"])["text"]

      saved =
        Repo.update!(
          Ecto.Changeset.change(run,
            status: unquote(status),
            result: body,
            result_sha256: CanonicalJSON.digest(body)
          )
        )

      assert {:error, _} = Learning.fail(run.id, :output_contract_failed, failure_receipt(run))
      assert Repo.get!(LearningRun, run.id) == saved
    end
  end

  test "a stale attempt without a result cannot be converted to an execution failure" do
    run = retained_run!()

    # A source change can finish custody before a model returns. The status
    # guard must protect that outcome independently of the retained-result guard.
    stale =
      Repo.update!(
        Ecto.Changeset.change(run, status: :stale, error_code: "learning_context_stale")
      )

    assert stale.result == nil
    assert stale.result_sha256 == nil

    assert {:error, :learning_attempt_finished} =
             Learning.fail(run.id, :output_contract_failed, failure_receipt(run))

    assert Repo.get!(LearningRun, run.id) == stale
  end

  test "failure recording cannot repopulate a pruned run or its producer" do
    run = retained_run!()

    pruned =
      Repo.update!(Ecto.Changeset.change(run, prompt: nil, pruned_at: DateTime.utc_now()))

    assert {:error, :learning_source_stale} =
             Learning.fail(run.id, :output_contract_failed, failure_receipt(run))

    assert Repo.get!(LearningRun, run.id) == pruned
  end

  test "failure recording after channel deletion is audit-only and cannot authorize another attempt" do
    entries = Fixtures.inputs!()
    ids = Enum.map(entries, & &1.id)
    assert {:ok, run} = prepare_with_custody(ids, @policy)
    delete_membership!()
    before = protected_rows()

    assert {:ok, failed} = Learning.fail(run.id, :output_contract_failed, failure_receipt(run))
    assert frozen(failed) == frozen(run)
    assert protected_rows() == before
    assert {:error, :learning_source_stale} = prepare_with_custody(ids, @policy)
    assert Repo.get!(LearningRun, run.id) == failed
    assert Repo.aggregate(LearningRun, :count) == 1
  end

  for change <- [:edit, :delete, :prune, :conversation, :repository, :expiry] do
    test "a retry after #{change} cannot refresh or disclose the old failed batch" do
      entries = Fixtures.inputs!()
      ids = Enum.map(entries, & &1.id)
      assert {:ok, run} = prepare_with_custody(ids, @policy)
      assert {:ok, failed} = Learning.fail(run.id, :output_contract_failed, failure_receipt(run))
      change_source!(hd(entries), unquote(change))

      assert {:error, :learning_source_stale} = prepare_with_custody(ids, @policy)
      assert Repo.get!(LearningRun, run.id) == failed
      assert Repo.aggregate(LearningRun, :count) == 1
    end
  end

  test "only execution failures spend the durable budget and retries get distinct custody identities" do
    entries = Fixtures.inputs!()
    ids = Enum.map(entries, & &1.id)
    assert {:ok, initial} = prepare_with_custody(ids, @policy)

    Repo.update!(
      Ecto.Changeset.change(initial, status: :stale, error_code: "learning_context_stale")
    )

    generations =
      for generation <- 2..4 do
        assert {:ok, run} = prepare_with_custody(ids, @policy)
        assert run.generation == generation
        assert {:ok, ^run} = Learning.authorize(run.id)
        receipt = failure_receipt(run)
        assert {:ok, failed} = Learning.fail(run.id, :output_contract_failed, receipt)
        assert {:ok, ^failed} = Learning.fail(run.id, :output_contract_failed, receipt)
        failed
      end

    assert generations |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3
    assert {:error, :learning_retry_exhausted} = prepare_with_custody(ids, @policy)
    assert Repo.aggregate(LearningRun, :count) == 4
  end

  defp prepare_with_custody(ids, policy) do
    case Learning.prepare(ids, policy) do
      {:ok, %{status: :prepared} = run} -> {:ok, bind_failure_custody(run)}
      other -> other
    end
  end

  defp bind_failure_custody(run) do
    receipt = failure_receipt(run)
    {:ok, _} = FleetSession.ensure(run)
    {:ok, _} = FleetSession.bind(run, receipt["session_id"])
    {:ok, bound} = Learning.bind_turn(run.id, receipt["session_id"], receipt["turn_id"])
    bound
  end

  defp seed_failures!(initial, count) do
    for generation <- 1..count do
      run =
        if generation == 1 do
          initial
        else
          attributes =
            initial
            |> Map.from_struct()
            |> Map.delete(:__meta__)
            |> Map.merge(%{id: Ecto.UUID.generate(), generation: generation})

          Repo.insert!(struct!(LearningRun, attributes))
        end

      # Deterministic host failure-state setup, not three invented model runs.
      Repo.update!(
        Ecto.Changeset.change(run,
          status: :rejected,
          error_code: "output_contract_failed",
          producer: failure_receipt(run)
        )
      )
    end
  end

  defp failure_receipt(run) do
    fixture = fixture()
    remote = fixture["remote_error"]
    actual? = run.id == fixture["learning_run"]["id"]

    remote
    |> Map.take(~w(state error_code finished_at))
    |> Map.merge(%{
      "session_id" =>
        if(actual?, do: remote["session_id"], else: "host-contract-session:#{run.id}"),
      "turn_id" => if(actual?, do: remote["id"], else: "host-contract-turn:#{run.id}"),
      "target" => "host-contract-test-provider",
      "prompt_sha256" => run.prompt_sha256
    })
  end

  defp retained_run! do
    raw = fixture()["learning_run"]
    assert raw["status"] == "prepared"

    # Matching custody was added after this immutable capture. Its empty host
    # default is not part of the recorded prompt, result, or producer evidence.
    captured_fields =
      LearningRun.__schema__(:fields) --
        [
          :match_refs,
          :batch_id,
          :batch_budget_version,
          :rebuild,
          :started_at,
          :submit_revision,
          :coop_turn_id,
          :candidate_attempt,
          :validation_receipt,
          :stop_receipt,
          :remote_stopped_at,
          :reconcile_attempt_count
        ]

    attributes =
      Map.new(captured_fields, fn field ->
        value = Map.fetch!(raw, Atom.to_string(field))

        value =
          cond do
            field in ~w(inputs source_dependencies knowledge omissions output_schema producer)a ->
              Jason.decode!(value)

            field == :status ->
              :prepared

            field in [:inserted_at, :updated_at] ->
              value |> NaiveDateTime.from_iso8601!() |> DateTime.from_naive!("Etc/UTC")

            true ->
              value
          end

        {field, value}
      end)

    struct!(LearningRun, attributes) |> Repo.insert!() |> bind_failure_custody()
  end

  defp change_source!(entry, event) when event in [:edit, :delete] do
    changed = %{
      entry
      | id: Ecto.UUID.generate(),
        revision: entry.revision + 1,
        event_kind: event,
        event_fingerprint: String.duplicate("c", 64)
    }

    assert {:ok, :ok} = Repo.transaction(fn -> Observations.receive_in_transaction(changed) end)
  end

  defp change_source!(entry, :prune),
    do: Repo.update!(Ecto.Changeset.change(entry, operational_pruned_at: DateTime.utc_now()))

  defp change_source!(entry, :conversation),
    do:
      Repo.update!(
        Ecto.Changeset.change(entry, destination_conversation_ref: "slack:OTHER:CHANNEL")
      )

  defp change_source!(entry, :repository),
    do: Repo.update!(Ecto.Changeset.change(entry, repository_ref: "other-repository"))

  defp change_source!(entry, :expiry) do
    prior = Application.get_env(:responder, :retention)
    Application.put_env(:responder, :retention, %{conversation_memory_seconds: 3600})
    on_exit(fn -> Application.put_env(:responder, :retention, prior) end)
    observation = Repo.get!(ConversationObservation, entry.id)

    Repo.update!(
      Ecto.Changeset.change(observation, updated_at: DateTime.add(DateTime.utc_now(), -3601))
    )
  end

  defp delete_membership! do
    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: "T01J1LW4DF1",
      channel_ref: "C08MMETA3U3",
      private: false,
      external_shared: false,
      generation: 1,
      status: :deleted,
      joined_at: DateTime.utc_now(),
      deleted_at: DateTime.utc_now()
    })
  end

  defp frozen(run),
    do:
      Map.take(
        run,
        ~w(id batch_key generation inputs source_dependencies knowledge omissions policy policy_digest prompt prompt_sha256 output_schema inserted_at)a
      )

  defp protected_rows,
    do:
      Enum.map(
        [
          Entry,
          ConversationObservation,
          ConversationKnowledge,
          KnowledgeRevision,
          Episode,
          Event,
          Turn
        ],
        &Repo.all/1
      )

  defp fixture, do: @fixture |> File.read!() |> Jason.decode!()
  defp sha256(text), do: Base.encode16(:crypto.hash(:sha256, text), case: :lower)
end

defmodule Responder.State.LearningFailureConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Learning.FleetSession
  alias Responder.Repo
  alias Responder.State.{ConversationObservation, Learning, LearningRun}

  @policy %{policy: "recorded-read-only-policy", policy_digest: String.duplicate("a", 64)}

  # Coverage of the batch-lock invariant at the new failure boundary. This is
  # a two-connection host test, not evidence of another provider judgment.
  test "concurrent recovery requests share one fresh generation after a terminal failure" do
    Sandbox.unboxed_run(Repo, fn ->
      baseline = fixture_counts()
      entries = Fixtures.inputs!()
      ids = Enum.map(entries, & &1.id)
      assert {:ok, run} = prepare_with_custody(ids, @policy)

      try do
        remote =
          "testdata/learning/retained-output-contract-failure.json"
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("remote_error")

        receipt =
          remote
          |> Map.take(~w(state error_code finished_at))
          |> Map.merge(%{
            "session_id" => "host-contract-session:#{run.id}",
            "turn_id" => "host-contract-turn:#{run.id}",
            "target" => "host-contract-test-provider",
            "prompt_sha256" => run.prompt_sha256
          })

        assert {:ok, failed} = Learning.fail(run.id, :output_contract_failed, receipt)
        assert_shared_retry!(run, ids)
        assert Repo.get!(LearningRun, run.id) == failed
      after
        Repo.delete_all(
          from(s in Responder.Work.Session,
            where:
              s.learning_run_id in subquery(
                from(r in LearningRun, where: r.batch_key == ^run.batch_key, select: r.id)
              )
          )
        )

        Repo.delete_all(from(r in LearningRun, where: r.batch_key == ^run.batch_key))
        Repo.delete_all(from(o in ConversationObservation, where: o.source_input_id in ^ids))
        Repo.delete_all(from(e in Entry, where: e.id in ^ids))
        Repo.delete_all(from(e in Event, where: e.episode_id in ^ids))
        Repo.delete_all(from(e in Episode, where: e.id in ^ids))
      end

      assert fixture_counts() == baseline
    end)
  end

  defp prepare_with_custody(ids, policy) do
    case Learning.prepare(ids, policy) do
      {:ok, %{status: :prepared} = run} ->
        session_id = "host-contract-session:#{run.id}"
        turn_id = "host-contract-turn:#{run.id}"
        {:ok, _} = FleetSession.ensure(run)
        {:ok, _} = FleetSession.bind(run, session_id)
        Learning.bind_turn(run.id, session_id, turn_id)

      other ->
        other
    end
  end

  defp assert_shared_retry!(run, ids) do
    parent = self()
    <<lock::signed-64, _::binary>> = :crypto.hash(:sha256, "learning:" <> run.batch_key)

    first =
      unboxed_task(fn ->
        Repo.transaction(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock])
          send(parent, {:retry_locked, backend_pid()})
          receive do: (:prepare -> prepare_with_custody(ids, @policy))
        end)
      end)

    second =
      unboxed_task(fn ->
        receive do: (:prepare -> :ok)
        send(parent, {:retry_started, backend_pid()})
        prepare_with_custody(ids, @policy)
      end)

    try do
      assert_receive {:retry_locked, first_backend}, 5000
      send(second.pid, :prepare)
      assert_receive {:retry_started, second_backend}, 5000
      assert first_backend != second_backend
      await_blocked_by(second_backend, first_backend)
      send(first.pid, :prepare)
      assert {:ok, {:ok, fresh}} = Task.await(first, 5000)
      assert {:ok, same} = Task.await(second, 5000)
      assert fresh.id == same.id
      assert fresh.generation == 2
      assert fresh.status == :prepared

      assert Repo.aggregate(from(r in LearningRun, where: r.batch_key == ^run.batch_key), :count) ==
               2
    after
      stop_tasks([first, second])
    end
  end

  defp fixture_counts,
    do:
      Enum.map(
        [LearningRun, ConversationObservation, Entry, Event, Episode],
        &Repo.aggregate(&1, :count)
      )
end
