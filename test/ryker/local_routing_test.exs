defmodule Ryker.LocalRoutingTest do
  @moduledoc """
  Phase 1 of a self-hosted routing model, shadow mode (Andrew, 2026-09-27:
  "build/fine-tune our own super-efficient self hosted model later ... So we
  can do more on free routing steps more accurately and fallback to large
  provider models only when needed").

  After routing's decision is accepted, the local model is asked the exact
  prompt the provider answered. Its answer goes through routing's own checks
  and is compared with the decision Ryker kept. Routing never waits for it and
  never uses it: every test here holds one of those two lines.

  The provider's answers and the local model's are real ones, harvested from
  the live install (`Ryker.Fixtures.LocalRouting`); the local endpoint is an
  in-process OpenAI-compatible double, never a model.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query
  import Ryker.TestHelpers, only: [eventually: 1]

  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission.{Attempt, Executor}
  alias Ryker.Fixtures.LocalRouting, as: Harvested
  alias Ryker.Ingress.Inbox
  alias Ryker.LocalRouting
  alias Ryker.LocalRouting.{Comparison, Schema, Worker}
  alias Ryker.Settings
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI

  @actor "control-plane:local"
  # The harvested messages arrived after the saved prices took effect, so the
  # provider's cost is estimated from them.
  @now ~U[2026-09-26 18:01:04.000000Z]
  @model "qwen2.5:3b"

  defmodule LocalModel do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(options), do: options

    # Answers each request with the next scripted answer, and tells the test
    # exactly what it was asked.
    @impl true
    def call(conn, {test, script}) do
      {:ok, body, conn} = read_body(conn, length: 4_000_000)
      send(test, {:local_request, conn.method, conn.request_path, Jason.decode!(body)})

      case Agent.get_and_update(script, fn
             [next | rest] -> {next, rest}
             [] -> {:none, []}
           end) do
        {:answer, content} -> completion(conn, content, "stop")
        {:cut_off, content} -> completion(conn, content, "length")
        {:status, status, text} -> send_resp(conn, status, text)
        {:hang, milliseconds} -> hang(conn, milliseconds)
        :none -> send_resp(conn, 500, "no answer scripted")
      end
    end

    defp completion(conn, content, finish_reason) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "id" => "chatcmpl-test",
          "object" => "chat.completion",
          "model" => "qwen2.5:3b",
          "choices" => [
            %{
              "index" => 0,
              "finish_reason" => finish_reason,
              "message" => %{"role" => "assistant", "content" => content}
            }
          ],
          "usage" => %{
            "prompt_tokens" => 4_213,
            "completion_tokens" => 58,
            "total_tokens" => 4_271
          }
        })
      )
    end

    defp hang(conn, milliseconds) do
      Process.sleep(milliseconds)
      send_resp(conn, 504, "too late")
    end
  end

  test "a message routed while the local model is off leaves nothing to compare" do
    endpoint = local_model!([{:answer, Harvested.hi_quick_reply()}])

    # Before settings exist at all, and then with the setting at its default.
    first = route!(Harvested.hi_quick_reply(), "Ev-local-off-unset")
    initialize!()
    second = route!(Harvested.hi_quick_reply(), "Ev-local-off-default")

    assert Settings.fetch!().work.local_routing_mode == :off
    assert first.status == :decided and second.status == :decided
    assert Repo.aggregate(Comparison, :count) == 0
    assert LocalRouting.run_next(options(endpoint)) == :idle
    refute_received {:local_request, _method, _path, _body}
  end

  test "routing decides and saves exactly as before and never waits for the local model" do
    # The comparison is a shadow of routing, never a step of it. The local
    # endpoint here would hang for a minute; routing still finishes at once,
    # decides the same thing it decides with the comparison off, and has not
    # asked the local model anything by the time it has saved.
    endpoint = local_model!([{:hang, 60_000}])
    initialize!()
    off = route!(Harvested.hi_quick_reply(), "Ev-local-unchanged-off")

    shadow!(endpoint)
    started = System.monotonic_time(:millisecond)
    shadowed = route!(Harvested.hi_quick_reply(), "Ev-local-unchanged-shadow")
    assert System.monotonic_time(:millisecond) - started < 5_000

    refute_received {:local_request, _method, _path, _body}

    for field <- [:status, :decision_action, :decision_document, :decision_fingerprint] do
      assert Map.fetch!(shadowed, field) == Map.fetch!(off, field), "#{field} changed"
    end

    assert [%Comparison{status: :pending, attempt_count: 0} = queued] = Repo.all(Comparison)
    assert queued.input_id == shadowed.id
    assert queued.generation == shadowed.execution_generation
  end

  test "an answer that decides what the provider decided agrees, beside the provider's cost and time" do
    endpoint = local_model!([{:answer, Harvested.hi_again_quick_reply()}])
    initialize!()
    shadow!(endpoint)
    entry = route!(Harvested.hi_quick_reply(), "Ev-local-agrees")
    attempt = Repo.get_by!(Attempt, input_id: entry.id, generation: entry.execution_generation)

    assert {:ran, %Comparison{}} = LocalRouting.run_next(options(endpoint))

    # The exact prompt the provider answered, and routing's own contract as
    # the structured output the local server holds its answer to.
    assert_received {:local_request, "POST", "/v1/chat/completions", request}
    assert request["model"] == @model
    assert request["messages"] == [%{"role" => "user", "content" => attempt.submission["prompt"]}]
    assert request["stream"] == false

    assert request["response_format"] == %{
             "type" => "json_schema",
             "json_schema" => %{
               "name" => "ryker_routing_decision",
               "schema" => Schema.local(attempt.submission["output_schema"]),
               "strict" => true
             }
           }

    comparison = Repo.one!(Comparison)
    assert comparison.status == :compared
    assert comparison.valid
    # The words and the reason differ; what Ryker would do next does not.
    assert comparison.agrees
    assert comparison.differing_fields == []
    assert comparison.local_model == @model
    assert comparison.local_input_tokens == 4_213
    assert comparison.local_output_tokens == 58
    assert is_integer(comparison.local_ms) and comparison.local_ms >= 0
    assert comparison.provider_ms == Harvested.provider_ms()
    assert Decimal.equal?(comparison.provider_cost_usd, Harvested.provider_cost_usd())
    assert comparison.provider_cost_estimated
    assert comparison.attempt_count == 1
  end

  test "an answer that decides differently records the fields that would change what Ryker does" do
    endpoint = local_model!([{:answer, Harvested.deploy_script_reply()}])
    initialize!()
    shadow!(endpoint)
    route!(Harvested.hi_quick_reply(), "Ev-local-disagrees")

    assert {:ran, _comparison} = LocalRouting.run_next(options(endpoint))

    comparison = Repo.one!(Comparison)
    assert comparison.status == :compared
    assert comparison.valid
    refute comparison.agrees
    # A reply starts conversation work where the provider answered at once.
    assert comparison.differing_fields == ["action", "work_class"]
    assert Jason.decode!(comparison.local_answer)["action"] == "reply"
  end

  test "an answer routing's own checks refuse is recorded as invalid with why, and asked once" do
    # A real answer in the contract of an earlier day: the fields routing
    # checks today are not the ones it holds. A model that answers that way
    # has answered; asking again would only spend the local machine.
    endpoint = local_model!([{:answer, Harvested.hi_again_old_contract()}])
    initialize!()
    shadow!(endpoint)
    route!(Harvested.hi_quick_reply(), "Ev-local-invalid")

    assert {:ran, _comparison} = LocalRouting.run_next(options(endpoint))
    assert LocalRouting.run_next(options(endpoint)) == :idle

    comparison = Repo.one!(Comparison)
    assert comparison.status == :compared
    refute comparison.valid
    assert comparison.invalid_reason == "decision:fields"
    assert comparison.agrees == nil
    assert comparison.attempt_count == 1
    assert_received {:local_request, "POST", _path, _body}
    refute_received {:local_request, _method, _path, _body}
  end

  test "an answer cut off at the local model's token limit is invalid, not retried" do
    endpoint = local_model!([{:cut_off, ~s({"action":"quick_reply","episode_ref":null,"mess)}])
    initialize!()
    shadow!(endpoint)
    route!(Harvested.hi_quick_reply(), "Ev-local-cut-off")

    assert {:ran, _comparison} = LocalRouting.run_next(options(endpoint))

    assert %Comparison{status: :compared, valid: false, invalid_reason: "cut_off"} =
             Repo.one!(Comparison)
  end

  test "an endpoint that cannot be reached is asked again later, then given up" do
    # Nothing listens on this port: the Mac running Ollama is asleep, or it
    # was never started. Each try waits longer; the last one gives up and says
    # why, and the comparison never runs again.
    endpoint = "http://127.0.0.1:#{unused_port!()}/v1"
    initialize!()
    shadow!(endpoint)
    route!(Harvested.hi_quick_reply(), "Ev-local-unreachable")
    start = ~U[2026-09-27 10:00:00.000000Z]
    options = options(endpoint, max_attempts: 3, retry_base_seconds: 30, retry_max_seconds: 600)

    assert {:ran, _first} = LocalRouting.run_next(at(options, start))
    first = Repo.one!(Comparison)
    assert first.status == :pending
    assert first.attempt_count == 1
    assert first.last_error =~ "could not reach"
    assert DateTime.compare(first.next_attempt_at, DateTime.add(start, 30)) == :eq

    # Not due yet: nothing is asked, and an idle worker sleeps until the retry.
    assert LocalRouting.run_next(at(options, DateTime.add(start, 29))) == :idle
    assert LocalRouting.next_due_at(start) == DateTime.add(start, 30)

    assert {:ran, _second} = LocalRouting.run_next(at(options, DateTime.add(start, 30)))
    second = Repo.one!(Comparison)
    assert second.status == :pending
    assert second.attempt_count == 2
    assert DateTime.compare(second.next_attempt_at, DateTime.add(start, 150)) == :eq

    assert {:ran, _third} = LocalRouting.run_next(at(options, DateTime.add(start, 150)))
    given_up = Repo.one!(Comparison)
    assert given_up.status == :failed
    assert given_up.attempt_count == 3
    assert given_up.last_error =~ "could not reach"
    assert given_up.next_attempt_at == nil
    assert LocalRouting.run_next(at(options, DateTime.add(start, 10_000))) == :idle
    assert LocalRouting.next_due_at(start) == nil
  end

  test "an endpoint that refuses the request is given up at once with what it said" do
    # Ollama answers 404 for a model that was never pulled; asking again in
    # a minute gets the same answer.
    endpoint =
      local_model!([
        {:status, 404, ~s({"error":"model \\"qwen2.5:3b\\" not found, try pulling it first"})}
      ])

    initialize!()
    shadow!(endpoint)
    route!(Harvested.hi_quick_reply(), "Ev-local-refused")

    assert {:ran, _comparison} = LocalRouting.run_next(options(endpoint))

    comparison = Repo.one!(Comparison)
    assert comparison.status == :failed
    assert comparison.attempt_count == 1
    assert comparison.last_error =~ "404"
    assert comparison.last_error =~ "not found, try pulling it first"
  end

  test "a local model that never answers is cut off at the firm timeout and tried again later" do
    endpoint = local_model!([{:hang, 1_500}])
    initialize!()
    shadow!(endpoint)
    route!(Harvested.hi_quick_reply(), "Ev-local-timeout")

    started = System.monotonic_time(:millisecond)
    assert {:ran, _comparison} = LocalRouting.run_next(options(endpoint, timeout_ms: 200))
    assert System.monotonic_time(:millisecond) - started < 1_200

    comparison = Repo.one!(Comparison)
    assert comparison.status == :pending
    assert comparison.last_error =~ "did not answer within 0.2 s"
  end

  test "a comparison routing queues wakes the idle lane, which asks the local model at once" do
    endpoint = local_model!([{:answer, Harvested.hi_again_quick_reply()}])
    initialize!()
    shadow!(endpoint)

    # A minute-long safety net: only routing's announcement can bring the
    # lane back in time.
    start_supervised!(
      {Worker,
       endpoint: endpoint,
       model: @model,
       max_attempts: 4,
       poll_interval_ms: 1_000,
       retry_base_seconds: 30,
       retry_max_seconds: 600,
       timeout_ms: 5_000,
       idle_interval_ms: 60_000,
       name: nil}
    )

    route!(Harvested.hi_quick_reply(), "Ev-local-wakes")

    assert eventually(fn -> match?([%Comparison{status: :compared}], Repo.all(Comparison)) end)
    assert_received {:local_request, "POST", "/v1/chat/completions", _request}
  end

  test "a comparison whose prompt retention already removed is given up without asking" do
    endpoint = local_model!([{:answer, Harvested.hi_quick_reply()}])
    initialize!()
    shadow!(endpoint)
    entry = route!(Harvested.hi_quick_reply(), "Ev-local-pruned")

    Repo.update_all(
      from(attempt in Attempt, where: attempt.input_id == ^entry.id),
      set: [submission: %{"retention" => "pruned"}, operational_pruned_at: DateTime.utc_now()]
    )

    assert {:ran, _comparison} = LocalRouting.run_next(options(endpoint))
    assert %Comparison{status: :failed, last_error: reason} = Repo.one!(Comparison)
    assert reason =~ "no longer kept"
    refute_received {:local_request, _method, _path, _body}
  end

  defp initialize!, do: {:ok, _snapshot} = Settings.initialize(@actor)

  defp shadow!(endpoint) do
    snapshot = Settings.fetch!()

    {:ok, _saved} =
      Settings.save_work(
        %{
          local_routing_mode: :shadow,
          local_routing_endpoint: endpoint,
          local_routing_model: @model
        },
        snapshot.installation.revision,
        @actor
      )
  end

  defp local_model!(script) do
    {:ok, answers} = Agent.start_link(fn -> script end)
    port = unused_port!()

    start_supervised!(
      Bandit.child_spec(
        ip: {127, 0, 0, 1},
        plug: {LocalModel, {self(), answers}},
        port: port,
        startup_log: false
      )
    )

    "http://127.0.0.1:#{port}/v1"
  end

  # One Slack message routed by the provider, as a live install routes it:
  # the recorded answer is the provider's, with what that call measured.
  defp route!(provider_answer, event_ref) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => Harvested.hi_text()},
        event_kind: :message,
        event_ref: event_ref,
        message_ref: "1787832001.#{:erlang.phash2(event_ref, 999_999)}",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TE5D7C8842D32"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    {:ok, %{entry: claimed, lease_ref: lease_ref}} = Inbox.claim_next("local:test", @now, 300)
    assert claimed.id == entry.id

    # Each routing run is its own Coop turn, so each decision its own record.
    {:ok, fake} =
      FakeAPI.start_link([provider_answer],
        turn_report: Harvested.provider_report(),
        turn_id_override: "turn_#{event_ref}"
      )

    Agent.update(fake, &put_in(&1, [:session, "target"], Harvested.provider_target()))

    {:ok, _execution} =
      Executor.run(Inbox.ref(entry),
        api: FakeAPI,
        client: fake,
        lease_ref: lease_ref,
        max_polls: 10,
        now: fn -> @now end,
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        poll_interval_ms: 0,
        renew_lease: fn -> :ok end,
        sleep: fn _milliseconds -> :ok end
      )

    {:ok, decided} = Inbox.fetch(Inbox.ref(entry))
    decided
  end

  defp options(endpoint, overrides \\ []) do
    Keyword.merge(
      [
        endpoint: endpoint,
        model: @model,
        timeout_ms: 5_000,
        max_attempts: 4,
        retry_base_seconds: 30,
        retry_max_seconds: 600
      ],
      overrides
    )
  end

  defp at(options, now), do: Keyword.put(options, :now, fn -> now end)

  defp unused_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
