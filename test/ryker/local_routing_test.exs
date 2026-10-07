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
  alias Ryker.Admission.{Attempt, Executor}
  alias Ryker.ControlPlane.LocalRoutingProjection
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.LocalRouting, as: Harvested
  alias Ryker.Ingress.Inbox
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.LocalRouting
  alias Ryker.LocalRouting.{Comparison, Schema, Worker}
  alias Ryker.Memories.Forgetting
  alias Ryker.Settings
  alias Ryker.Slack.ChannelConfigurations
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI

  @moduletag isolation: "REPEATABLE READ"

  @actor "control-plane:local"
  @workspace "TE5D7C8842D32"
  @channel "C456"
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
      # A local model that answers after Ryker stopped waiting for it.
      # credo:disable-for-next-line Ryker.Checks.TestNoProcessSleep
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

  describe "a person forgetting wins" do
    # A comparison holds no words of its own: the lane reads the exact prompt
    # the provider was sent when it asks. Nothing checked whether the person
    # had since taken the message back, so a comparison waiting on a local
    # model that was down sent a deleted message's words to it days after
    # the deletion (found in review, 2026-09-28). The prompt of a later
    # message quotes the earlier ones of its channel, so that one goes too.
    test "a deleted message's comparison is never sent to the local model" do
      endpoint = local_model!([{:answer, Harvested.hi_again_quick_reply()}])
      initialize!()
      shadow!(endpoint)
      route!(Harvested.hi_quick_reply(), "Ev-local-deleted")
      route!(Harvested.hi_quick_reply(), "Ev-local-deleted-2", at: 1)
      other = route!(Harvested.hi_quick_reply(), "Ev-local-deleted-3", at: 2, channel: "C999")

      delete!("Ev-local-deleted")

      assert kept() == [other.id], "a deleted message's comparison is still kept"
      drain(endpoint)

      assert local_prompts() == [prompt(other)],
             "the local model was sent a deleted message's prompt"

      assert [%Comparison{input_id: id, status: :compared}] = Repo.all(Comparison)
      assert id == other.id
    end

    # Once compared, a comparison keeps the local model's answer to the
    # prompt, and the answer can repeat the message's words. Only waiting
    # comparisons were withdrawn, so a deleted message's answer stayed until
    # its bodies expired (found in review, 2026-09-28). Usage & cost reads the
    # comparisons that are left.
    test "a deleted message's compared comparison is erased, and Usage counts only what is left" do
      endpoint =
        local_model!([
          {:answer, Harvested.deploy_script_reply()},
          {:answer, Harvested.hi_again_quick_reply()}
        ])

      initialize!()
      shadow!(endpoint)
      route!(Harvested.hi_quick_reply(), "Ev-local-compared")
      other = route!(Harvested.hi_quick_reply(), "Ev-local-compared-2", at: 1, channel: "C999")
      drain(endpoint)

      compared = LocalRoutingProjection.project(nil, "all")
      differed = Enum.sum(Enum.map(compared.decisions, &(&1.valid - &1.agreed)))
      assert {compared.figures.compared, differed} == {2, 1}

      delete!("Ev-local-compared")

      assert kept() == [other.id], "the local model's answer to a deleted message is still kept"

      usage = LocalRoutingProjection.project(nil, "all")

      assert Map.take(usage.figures, [:compared, :valid, :agreed, :waiting, :failed]) ==
               %{compared: 1, valid: 1, agreed: 1, waiting: 0, failed: 0}

      assert usage.differences == []
    end

    # The lane holds a comparison it took before the deletion committed, so
    # withdrawing the waiting ones is not enough: it checks again just before
    # it sends.
    test "a message deleted after the lane took its comparison is still never sent" do
      endpoint = local_model!([{:answer, Harvested.hi_again_quick_reply()}])
      initialize!()
      shadow!(endpoint)
      route!(Harvested.hi_quick_reply(), "Ev-local-deleted-late")
      delete_as_the_lane_reads!("Ev-local-deleted-late")

      assert {:ran, _comparison} = LocalRouting.run_next(options(endpoint))

      assert local_prompts() == [], "the local model was sent a deleted message's prompt"
      assert Repo.all(Comparison) == []
      assert LocalRouting.run_next(options(endpoint)) == :idle
    end

    # An edit replaces the words a person no longer wants said, and the local
    # model's answer can repeat them. Only deleting reached a comparison, so
    # the local model was still sent the words an edit had replaced.
    test "editing a message erases every comparison that quoted its old words" do
      endpoint =
        local_model!([
          {:answer, Harvested.hi_again_quick_reply()},
          {:answer, Harvested.hi_again_quick_reply()}
        ])

      initialize!()
      shadow!(endpoint)
      route!(Harvested.hi_quick_reply(), "Ev-local-edited")
      drain(endpoint)
      [_sent_before_it_was_edited] = local_prompts()
      route!(Harvested.hi_quick_reply(), "Ev-local-edited-2", at: 1)
      other = route!(Harvested.hi_quick_reply(), "Ev-local-edited-3", at: 2, channel: "C999")

      edit!("Ev-local-edited", "hi, reply with two words")

      assert kept() == [other.id], "a comparison quoting an edited message's old words is kept"
      drain(endpoint)

      assert local_prompts() == [prompt(other)],
             "the local model was sent the words an edit replaced"
    end

    test "forgetting what was learned from a message erases every comparison that quoted it" do
      endpoint =
        local_model!([
          {:answer, Harvested.hi_again_quick_reply()},
          {:answer, Harvested.hi_again_quick_reply()}
        ])

      initialize!()
      shadow!(endpoint)
      first = route!(Harvested.hi_quick_reply(), "Ev-local-learned")
      drain(endpoint)
      [_sent_before_it_was_forgotten] = local_prompts()
      route!(Harvested.hi_quick_reply(), "Ev-local-learned-2", at: 1)
      other = route!(Harvested.hi_quick_reply(), "Ev-local-learned-3", at: 2, channel: "C999")

      assert {:ok, %{forgotten: [_topic]}} = Forgetting.forget_topic(topic!(first).id)

      assert kept() == [other.id], "a comparison quoting a forgotten message is still kept"
      drain(endpoint)

      assert local_prompts() == [prompt(other)],
             "the local model was sent a forgotten message's prompt"
    end

    test "deleting a Slack channel erases the comparisons from it" do
      endpoint =
        local_model!([
          {:answer, Harvested.hi_again_quick_reply()},
          {:answer, Harvested.hi_again_quick_reply()}
        ])

      initialize!()
      shadow!(endpoint)
      route!(Harvested.hi_quick_reply(), "Ev-local-channel")
      drain(endpoint)
      [_sent_before_it_was_deleted] = local_prompts()
      route!(Harvested.hi_quick_reply(), "Ev-local-channel-2", at: 1)
      other = route!(Harvested.hi_quick_reply(), "Ev-local-channel-3", at: 2, channel: "C999")

      assert {:ok, _deleted} =
               ChannelConfigurations.observe_membership(
                 %{
                   actor_ref: nil,
                   channel_ref: @channel,
                   event_ref: "event:delete-local-routing",
                   kind: :deleted,
                   occurred_at: Repo.now!(),
                   workspace_ref: @workspace
                 },
                 %{default_environment: nil, environments: []}
               )

      assert kept() == [other.id], "a comparison from a deleted channel is still kept"
      drain(endpoint)

      assert local_prompts() == [prompt(other)],
             "the local model was sent a deleted channel's prompt"
    end
  end

  # Asks the local model until nothing is due.
  defp drain(endpoint) do
    Enum.reduce_while(1..10, nil, fn _pass, _ ->
      case LocalRouting.run_next(options(endpoint)) do
        :idle -> {:halt, nil}
        {:ran, _comparison} -> {:cont, nil}
      end
    end)
  end

  # The messages with a comparison kept, waiting, compared or given up.
  defp kept do
    Repo.all(
      from(comparison in Comparison,
        order_by: comparison.inserted_at,
        select: comparison.input_id
      )
    )
  end

  # Every prompt the local model was sent so far.
  defp local_prompts do
    receive do
      {:local_request, _method, _path, %{"messages" => [%{"content" => prompt}]}} ->
        [prompt | local_prompts()]
    after
      0 -> []
    end
  end

  defp prompt(entry) do
    Repo.get_by!(Attempt, input_id: entry.id, generation: entry.execution_generation).submission[
      "prompt"
    ]
  end

  # The person deletes the message the first time the lane reads it back for
  # a comparison it has already taken.
  defp delete_as_the_lane_reads!(event_ref) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ryker, :repo, :query],
        &__MODULE__.delete_on_read/4,
        {self(), event_ref}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def delete_on_read(_event, _measurements, %{query: query}, {lane, event_ref}) do
    if self() == lane and not Process.get(:deleted_on_read?, false) and
         String.starts_with?(query, "SELECT") and
         String.contains?(query, ~s(FROM "ingress_inbox_entries")) do
      Process.put(:deleted_on_read?, true)
      delete!(event_ref)
    end
  end

  # The person deletes their message in Slack.
  defp delete!(event_ref) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: @channel,
        content: %{"text" => ""},
        event_kind: :delete,
        event_ref: event_ref <> "-deleted",
        message_ref: message_ref(event_ref),
        occurred_at: DateTime.add(@now, 60, :second),
        revision: 2,
        thread_ref: nil,
        workspace_ref: @workspace
      })

    {:ok, %{status: :recorded}} = Inbox.record(input)
  end

  # The person edits their message in Slack to say `text`.
  defp edit!(event_ref, text) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: @channel,
        content: %{"text" => text},
        event_kind: :edit,
        event_ref: event_ref <> "-edited",
        message_ref: message_ref(event_ref),
        occurred_at: DateTime.add(@now, 60, :second),
        revision: 2,
        thread_ref: nil,
        workspace_ref: @workspace
      })

    {:ok, %{status: :recorded}} = Inbox.record(input)
  end

  defp topic!(entry) do
    proposal = %{
      "topic_key" => "greeting",
      "title" => "Greeting",
      "summary" => "Greeting, as the message said it.",
      "topics" => ["greeting"],
      "anchors" => [],
      "target_ref" => nil,
      "expected_version" => 0
    }

    {:ok, :ok} = Repo.transaction(fn -> KnowledgeFixtures.record_topic(entry, proposal, []) end)
    Repo.one!(from(k in ConversationKnowledge, where: k.topic_key == "greeting"))
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
  # `at` puts it that many seconds after the first, in `channel`.
  defp route!(provider_answer, event_ref, options \\ []) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: Keyword.get(options, :channel, @channel),
        content: %{"text" => Harvested.hi_text()},
        event_kind: :message,
        event_ref: event_ref,
        message_ref: message_ref(event_ref),
        occurred_at: DateTime.add(@now, Keyword.get(options, :at, 0), :second),
        revision: 1,
        thread_ref: nil,
        workspace_ref: @workspace
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

  defp message_ref(event_ref), do: "1787832001.#{:erlang.phash2(event_ref, 999_999)}"

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
