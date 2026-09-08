defmodule Responder.Learning.ProviderFailureTest do
  use Responder.DataCase, async: false
  import Ecto.Query
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Learning.{Batch, Dispatcher}
  alias Responder.State.{KnowledgeRevision, LearningRun}
  alias Responder.TestSupport.FakeCoopAPI

  defmodule API do
    alias Responder.TestSupport.FakeCoopAPI, as: Fake

    defdelegate operation_by_key(client, key), to: Fake
    defdelegate get_session(client, id), to: Fake
    defdelegate get_turn(client, sid, tid), to: Fake

    def create_session(client, key, policy, ref) do
      Agent.update(client, fn state ->
        session = Map.put(state.session, "id", "host-contract-session:#{ref}")
        %{state | session: session}
      end)

      Fake.create_session(client, key, policy, ref)
    end

    def submit_frozen_turn(client, sid, key, revision, submission, nil, []) do
      Agent.update(client, &%{&1 | failed_turn_key: nil})

      {:ok, %{"turn" => identities}} =
        Fake.submit_turn(
          client,
          sid,
          key,
          revision,
          submission["prompt"],
          submission["output_schema"]
        )

      # Captured terminal failure, with only native identities remapped to the
      # current host custody. No candidate or successful model answer is invented.
      turn =
        Map.merge(Fake.state(client).terminal_fixture, Map.take(identities, ~w(id session_id)))

      Agent.update(client, &%{&1 | turn: turn})
      {:ok, %{"turn" => turn}}
    end
  end

  @settings %{
    policy: "recorded-read-only-policy",
    policy_digest: String.duplicate("a", 64),
    worker_ref: "learning-failure-test",
    quiet_seconds: 0,
    maximum_delay_seconds: 60,
    lease_seconds: 300,
    batch_size: 16,
    step_delay_seconds: 0,
    execution_timeout_seconds: 600,
    api: API
  }

  test "real dispatcher contract exhaustion corrects the next prompt without renewing its budget" do
    # Retained replay batch 371 exhausted three provider contract attempts. A
    # test-only failure recorder hid the live executor's generic error mapping,
    # buying identical blind retries despite the static correction being tested.
    _entries = Fixtures.inputs!()

    terminal =
      "testdata/learning/retained-output-contract-failure.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("remote_error")

    {:ok, fake} = FakeCoopAPI.start_link([], fail_first_turn: true)
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    Agent.update(fake, fn state ->
      state
      |> Map.put(:terminal_fixture, terminal)
      |> put_in([:session, "target"], "host-contract-test-provider")
    end)

    settings = Map.put(@settings, :client, fake)
    assert {:ok, %{status: :queued, start_count: 1}} = Dispatcher.run_once(settings)
    assert {:ok, %{status: :queued, start_count: 2}} = Dispatcher.run_once(settings)

    [first, second] = Repo.all(from(r in LearningRun, order_by: [asc: r.generation]))
    feedback = Jason.decode!(second.prompt)["previous_attempt_error"]

    assert is_map(feedback),
           "the live retry must receive the retained contract-failure correction"

    assert feedback["code"] == "output_contract_failed"
    assert feedback["instruction"] =~ "required JSON shape"
    assert first.error_code == "output_contract_failed"
    assert first.stop_receipt["state"] == "failed"
    assert first.stop_receipt["id"] == first.coop_turn_id
    assert first.remote_stopped_at != nil
    assert first.result == nil
    assert first.validation_receipt == nil

    assert {:ok, %{status: :deferred, start_count: 3, start_limit: 3}} =
             Dispatcher.run_once(settings)

    assert {:ok, :idle} = Dispatcher.run_once(settings)
    assert Repo.aggregate(Batch, :count) == 1
    assert Repo.aggregate(LearningRun, :count) == 3
    assert Repo.aggregate(KnowledgeRevision, :count) == 0
    assert FakeCoopAPI.state(fake).submit_count == 3
    assert FakeCoopAPI.state(fake).validations == []
  end
end
