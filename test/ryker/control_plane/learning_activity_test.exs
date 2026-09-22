defmodule Ryker.ControlPlane.LearningActivityTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.CanonicalJSON

  alias Ryker.ControlPlane.{
    ConversationMemory,
    CSRF,
    HTML,
    LearningActivity,
    LearningReceipt,
    Projection,
    Router
  }

  alias Ryker.Fixtures.Learning, as: Fixtures
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.{Batch, Batches, InputMembership}
  alias Ryker.Operator.Action
  alias Ryker.State.LearningRun
  alias Ryker.Work.{Custody, Turn}

  @settings %{
    policy: "inspection-policy",
    policy_digest: String.duplicate("a", 64),
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16
  }

  setup do
    previous = Application.get_env(:ryker, :learning)

    Application.put_env(:ryker, :learning, %{
      api: __MODULE__,
      client: %{},
      worker_ref: "inspection-test",
      policy: @settings.policy,
      policy_digest: @settings.policy_digest
    })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ryker, :learning, previous),
        else: Application.delete_env(:ryker, :learning)
    end)

    :ok
  end

  test "disabled learning is explicit and retained waiting messages are visible without claiming knowledge" do
    Application.delete_env(:ryker, :learning)
    inputs!()
    view = LearningActivity.project(%{})
    refute view.enabled
    assert view.waiting_inputs == 2
    assert view.oldest_waiting_at
    assert view.counts.no_change == 0
    html = HTML.memory(Projection.memory(), String.duplicate("s", 32)) |> IO.iodata_to_binary()
    assert html =~ "Learning is disabled"
    assert html =~ "2 messages waiting"
    assert html =~ "Current knowledge"
    assert html =~ "Conversation context"
    refute html =~ "Source excerpts"
    refute html =~ "A new source can rebuild this topic"
  end

  @tag :learning_count_labels
  test "a single message and model start use singular labels in learning activity" do
    # The live learning page showed "1 messages" and "1 model starts" in its
    # batch list and selected batch, obscuring an otherwise simple progress view.
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", %{@settings | batch_size: 1})
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)

    html =
      HTML.memory(Projection.memory(%{"batch" => claim.batch.id}), String.duplicate("s", 32))
      |> IO.iodata_to_binary()

    assert html =~ "1 message · 1 model start ·"
    assert html =~ "1 message · 1 of 3 approved model starts used"
    refute html =~ "1 messages"
    refute html =~ "1 model starts"
  end

  @tag :policy_recovery_ui
  test "retry explains its current policy and is unavailable when learning has no valid configuration" do
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_retry_exhausted")
    configuration = Application.fetch_env!(:ryker, :learning)
    Application.put_env(:ryker, :learning, %{configuration | policy: "available-account"})
    params = %{"batch" => claim.batch.id}

    html =
      HTML.memory(Projection.memory(params), String.duplicate("s", 32)) |> IO.iodata_to_binary()

    assert html =~ "current learning policy"
    assert html =~ "available-account"

    Application.delete_env(:ryker, :learning)
    selected = LearningActivity.project(params).selected
    refute selected.retry_available
    assert selected.retry_blocked =~ "Learning is disabled"
    Application.put_env(:ryker, :learning, %{})
    selected = LearningActivity.project(params).selected
    refute selected.retry_available
    assert selected.retry_blocked =~ "configuration"
  end

  test "no-change batches and every rejected frozen attempt remain inspectable without a topic revision" do
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)

    body =
      "testdata/learning/retained-output-contract-failure.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("public_responses")
      |> hd()
      |> Map.fetch!("text")

    Repo.update!(
      Ecto.Changeset.change(run,
        status: :rejected,
        result: body,
        error_code: "invalid_learning_result"
      )
    )

    assert {:ok, _} = Batches.finish(claim, :no_change, nil)

    view = ConversationMemory.project(%{"batch" => claim.batch.id, "attempt" => run.id})
    assert view.learning_activity.counts.no_change == 1
    assert view.learning_activity.selected.id == claim.batch.id
    assert view.learning_activity.selected.attempts |> Enum.map(& &1.id) == [run.id]
    assert view.learning.id == run.id
    assert view.learning.status == :rejected
    assert view.learning.error =~ "did not match"
    assert Enum.find(view.learning.sections, &(&1.id == "prompt")).artifact.text

    assert ConversationMemory.project(%{"batch" => Ecto.UUID.generate(), "attempt" => run.id}).learning ==
             nil

    html =
      HTML.memory(
        Projection.memory(%{"batch" => claim.batch.id, "attempt" => run.id}),
        String.duplicate("s", 32)
      )
      |> IO.iodata_to_binary()

    assert html =~ "No change needed"
    assert html =~ "Learning attempt 1"
    assert html =~ "Proposed topic updates"
    refute html =~ "The proposed topic updates accepted together"
  end

  test "learning attempt history is chronological even when a new source selection restarts generation numbers" do
    # Reselection preserves the same budget and old runs, but uses a new frozen
    # request key. Sorting only by its local generation puts old attempts first.
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-chronology", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    older = Repo.update!(Ecto.Changeset.change(run, generation: 3, status: :rejected))

    newer =
      older
      |> Map.from_struct()
      |> Map.drop([:__meta__, :id])
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        batch_key: CanonicalJSON.digest(%{"selection" => "structural-second-request"}),
        generation: 1,
        inserted_at: DateTime.add(older.inserted_at, 1, :second)
      })
      |> then(&Repo.insert!(struct!(LearningRun, &1)))

    view = LearningActivity.project(%{"batch" => claim.batch.id})
    assert Enum.map(view.selected.attempts, & &1.id) == [newer.id, older.id]
    assert Enum.map(view.selected.attempts, & &1.number) == [2, 1]
    assert LearningReceipt.project_attempt(claim.batch.id, newer.id, []).attempt_number == 2
  end

  test "a saved no-change attempt never becomes knowledge updated when its batch is reselected" do
    # Rebuild reselection reuses the batch. Using its latest status relabelled
    # earlier no-change attempts as successful updates. The result below is an
    # exact captured acknowledgement result; batch lifecycle here is structural.
    inputs!()
    assert {:ok, claim} = Batches.claim("immutable-attempt-label", @settings)
    assert {:ok, run} = Batches.prepare(claim)

    captured =
      "testdata/learning/recorded-no-change-result.json" |> File.read!() |> Jason.decode!()

    assert Base.encode16(:crypto.hash(:sha256, captured["result"]), case: :lower) ==
             captured["result_sha256"]

    assert CanonicalJSON.digest(captured["result"]) == captured["retained_run_result_sha256"]

    Repo.update!(Ecto.Changeset.change(run, status: :applied, result: captured["result"]))

    for status <- [:no_change, :queued, :running, :deferred, :applied] do
      set_batch_status!(claim.batch, status)
      assert [attempt] = LearningActivity.project(%{"batch" => claim.batch.id}).selected.attempts
      assert attempt.label == "No change needed", "batch #{status} rewrote the old outcome"
      refute Map.has_key?(attempt, :result)
      assert LearningReceipt.project_attempt(claim.batch.id, run.id, []).outcome == attempt.label
    end
  end

  test "pruned attempt results keep a neutral completion label instead of borrowing the batch outcome" do
    inputs!()
    assert {:ok, claim} = Batches.claim("pruned-attempt-label", @settings)
    assert {:ok, run} = Batches.prepare(claim)

    Repo.update!(
      Ecto.Changeset.change(run,
        status: :applied,
        result: nil,
        pruned_at: DateTime.utc_now()
      )
    )

    for status <- [:no_change, :applied] do
      set_batch_status!(claim.batch, status)
      assert [attempt] = LearningActivity.project(%{"batch" => claim.batch.id}).selected.attempts
      assert attempt.label == "Learning completed"
      assert LearningReceipt.project_attempt(claim.batch.id, run.id, []).outcome == attempt.label
    end
  end

  test "unresolved remote work blocks retry even when it belongs to another batch in the same scope" do
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, run} = Batches.prepare(claim)
    assert {:ok, _} = Batches.begin_execution(claim, run.id)
    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_remote_unresolved")

    second =
      Repo.insert!(%Batch{
        scope_key: claim.batch.scope_key,
        transport: claim.batch.transport,
        conversation_ref: claim.batch.conversation_ref,
        repository_ref: claim.batch.repository_ref,
        execution_mode: claim.batch.execution_mode,
        policy: @settings.policy,
        policy_digest: @settings.policy_digest,
        status: :deferred,
        input_count: 1
      })

    view = LearningActivity.project(%{"batch" => second.id})
    refute view.selected.retry_available
    assert view.selected.retry_blocked =~ "earlier model execution"

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(LearningRun, run.id),
        remote_stopped_at: DateTime.utc_now(),
        stop_receipt: %{
          "id" => "host-contract-turn:#{run.id}",
          "session_id" => "host-contract-session:#{run.id}",
          "state" => "cancelled"
        }
      )
    )

    assert LearningActivity.project(%{"batch" => second.id}).selected.retry_available
  end

  test "retry form binds the exact budget version and repeated submission grants only one start" do
    inputs!()
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_capacity_exceeded")
    secret = String.duplicate("s", 32)

    token =
      CSRF.token(
        secret,
        "learning:retry",
        LearningActivity.retry_resource(claim.batch.id, 0)
      )

    path = "/actions/learning/#{claim.batch.id}/retry"

    options =
      Router.init(%{
        csrf_secret: secret,
        actions: %{},
        observability: %{},
        projection: %{}
      })

    post = fn fields ->
      Plug.Test.conn(:post, path, URI.encode_query(fields))
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Router.call(options)
    end

    assert post.(%{"_token" => token, "budget_version" => "1"}).status == 403
    assert Repo.aggregate(Action, :count) == 0

    for _ <- 1..2 do
      response = post.(%{"_token" => token, "budget_version" => "0"})
      assert response.status == 303

      assert Plug.Conn.get_resp_header(response, "location") == [
               LearningActivity.path(claim.batch.id)
             ]
    end

    assert %{start_count: 0, start_limit: 1, budget_version: 1} = Repo.get!(Batch, claim.batch.id)
    assert [audit] = Repo.all(Action)
    assert audit.actor_ref == "control-plane:local"
    assert audit.action_ref == "control-plane:learning-retry:#{claim.batch.id}:0"
  end

  test "retry retires a withdrawn source while preserving the valid sibling and spending history" do
    # One withdrawn original used to strand all retained siblings in its batch.
    # Retrying must not resurrect it or prevent the surviving message learning.
    [first, second] = inputs!()
    {claim, response} = retry_with_withdrawn_sources([first])

    assert response.status == 303
    assert Repo.aggregate(Action, :count) == 1

    assert %{budget_version: 1, start_count: 0, start_limit: 1} =
             Repo.get!(Batch, claim.batch.id)

    assert Repo.get!(InputMembership, first.id).terminal_reason == "source_unavailable"
    assert Repo.get!(InputMembership, second.id).terminal_reason == nil
    assert {:ok, resumed} = Batches.claim("inspection-survivor", @settings)
    assert Enum.map(resumed.inputs, & &1.id) == [second.id]
  end

  test "withdrawing every source rejects retry without a grant or success audit" do
    {claim, response} = retry_with_withdrawn_sources(inputs!())
    assert response.status == 409
    assert response.resp_body =~ "cannot be retried with its old inputs"
    assert Repo.aggregate(Action, :count) == 0
    assert Repo.get!(Batch, claim.batch.id).budget_version == 0
  end

  defp retry_with_withdrawn_sources(withdrawn) do
    assert {:ok, claim} = Batches.claim("inspection-test", @settings)
    assert {:ok, _} = Batches.finish(claim, :deferred, "learning_capacity_exceeded")
    secret = String.duplicate("s", 32)

    token =
      CSRF.token(
        secret,
        "learning:retry",
        LearningActivity.retry_resource(claim.batch.id, 0)
      )

    Enum.each(withdrawn, fn entry ->
      Repo.update!(
        Ecto.Changeset.change(entry,
          operational_pruned_at: DateTime.utc_now(),
          content: %{"retention" => "pruned"}
        )
      )
    end)

    options =
      Router.init(%{
        csrf_secret: secret,
        actions: %{},
        observability: %{},
        projection: %{}
      })

    response =
      Plug.Test.conn(
        :post,
        "/actions/learning/#{claim.batch.id}/retry",
        URI.encode_query(%{"_token" => token, "budget_version" => "0"})
      )
      |> Map.put(:host, "localhost")
      |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
      |> Router.call(options)

    {claim, response}
  end

  test "a failed conversation handover remains visible without marking a delivered response failed" do
    # Source-capacity failures intentionally preserve an accepted response. The
    # operator must see the missing handover instead of assuming learning succeeded.
    [entry | _] = inputs!()

    {:ok, _} =
      Custody.pin_episode(
        entry.episode_id,
        "inspection-policy",
        @settings.policy_digest
      )

    {:ok, claim} = Custody.claim_next("inspection-handover", 60, :work)

    document =
      File.read!("testdata/elixir-eval/alert-controls-rejected-result.json") |> Jason.decode!()

    delivered_at = DateTime.utc_now()

    Repo.update_all(from(t in Turn, where: t.id == ^claim.turn.id),
      set: [
        status: :settled,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        next_attempt_at: nil,
        candidate: Jason.encode!(document),
        candidate_attempt: 1,
        candidate_sha256:
          :crypto.hash(:sha256, Jason.encode!(document)) |> Base.encode16(case: :lower),
        validation_intent: %{"decision" => "accept"},
        validation_intent_fingerprint: String.duplicate("e", 64),
        continuation: %{"kind" => "complete"},
        validation_receipt: "fixture:accepted-recorded-response",
        result_ref: "fixture:recorded-response",
        accepted_at: delivered_at,
        delivery_document: document,
        delivery_ref: "fixture:recorded-response",
        delivery_fingerprint: CanonicalJSON.digest(document),
        external_receipt: %{"message_ref" => entry.source_item_ref},
        external_receipt_fingerprint: String.duplicate("d", 64),
        delivered_at: delivered_at,
        summary_error_code: "source_capacity"
      ]
    )

    before = Repo.get!(Turn, claim.turn.id)
    view = LearningActivity.project(%{})
    assert view.handover_failures.total == 1
    assert [failure] = view.handover_failures.items
    assert failure.turn_id == claim.turn.id
    assert failure.response_status == "Response sent"
    assert failure.explanation =~ "source history exceeded"
    assert failure.request_path =~ "attempt=#{claim.turn.id}"
    html = HTML.memory(Projection.memory(), String.duplicate("s", 32)) |> IO.iodata_to_binary()
    assert html =~ "Conversation context not saved"
    assert html =~ "Response sent"
    assert html =~ "This does not change the response or its delivery status"
    assert Repo.get!(Turn, claim.turn.id) == before
  end

  defp inputs! do
    entries = Fixtures.inputs!()
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    Repo.update_all(Entry, set: [inserted_at: now, updated_at: now])
    entries
  end

  defp set_batch_status!(claimed, status) do
    fields = [:lease_ref, :lease_owner, :lease_expires_at]

    leases =
      if status == :running,
        do: Map.take(claimed, fields),
        else: Map.new(fields, &{&1, nil})

    claimed.id
    |> then(&Repo.get!(Batch, &1))
    |> Ecto.Changeset.change(Map.put(leases, :status, status))
    |> Repo.update!()
  end
end
