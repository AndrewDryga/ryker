defmodule Ryker.Evals.RoutingReplayTest do
  # Routing had no model eval: the world eval routes with a deterministic
  # stand-in, so a change to routing's instructions or contract could only be
  # tried on live traffic (2026-09-29). A replay asks the decisions Ryker kept
  # for training again under today's prompt. The requests here are built by
  # the host itself and the model's answers stand in, so these tests hold the
  # host to what it does with any answer; none calls a model.
  use ExUnit.Case, async: true

  alias Ryker.Admission.{Candidate, Context, Decision, Prompt}
  alias Ryker.Episodes.Episode
  alias Ryker.Evals.{CoopRunner, Job, RoutingReplay, RoutingReplayCase}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.TestSupport.FakeCoopAPI

  defmodule LocalModel do
    @moduledoc false
    @behaviour Plug

    import Plug.Conn

    @impl true
    def init(options), do: options

    # Answers each chat completion with the next scripted answer and tells
    # the test what it was asked.
    @impl true
    def call(conn, {test, script}) do
      {:ok, body, conn} = read_body(conn, length: 4_000_000)
      send(test, {:local_request, conn.request_path, Jason.decode!(body)})
      content = Agent.get_and_update(script, fn [next | rest] -> {next, rest} end)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "choices" => [
            %{
              "finish_reason" => "stop",
              "message" => %{"content" => content, "role" => "assistant"}
            }
          ],
          "usage" => %{"completion_tokens" => 40, "prompt_tokens" => 2_300}
        })
      )
    end
  end

  setup do
    context = context!()
    request = Prompt.build(context)
    [candidate] = request["context"]["candidates"]

    %{
      context: context,
      request: request,
      candidate: candidate["episode_ref"],
      example: line(request, context, continued(candidate["episode_ref"]))
    }
  end

  test "a recorded decision is asked with today's instructions under today's contract",
       %{context: context, request: request, example: line} do
    assert {:ok, replay} = RoutingReplayCase.new(line)

    assert replay.prompt == Prompt.render(request)
    refute replay.prompt =~ "Yesterday's wording."
    assert replay.schema == schema(context)
    assert replay.eval_id == "routing-replay:#{line["labels"]["example_id"]}"
  end

  # Andrew, 2026-10-01: "do the routing thing now". The local routing model's cascade is built
  # from which decisions it makes the same as the provider, and a week of live traffic is a few
  # dozen decisions while the routing examples hold every one Ryker kept. The local replay asks
  # the local model each recorded decision once, with no repair, since a cascade acts on its first
  # answer, and says for each recorded action how often it agreed and how long it took.
  test "a local model is asked each recorded decision once and scored per action",
       %{example: line, candidate: candidate, request: request, context: context} do
    {:ok, continued_case} = RoutingReplayCase.new(line)
    {:ok, quick_case} = RoutingReplayCase.new(line(request, context, quick_reply()))

    endpoint =
      local_model!([Jason.encode!(continued(candidate)), "The checkout outage again."])

    assert {:ok, result} =
             RoutingReplay.run_local([continued_case, quick_case], %{
               endpoint: endpoint,
               model: "qwen2.5:3b",
               timeout_ms: 5_000
             })

    # Exactly what routing's local comparison sends: the prompt as the one
    # user message, under routing's contract as structured output.
    assert_received {:local_request, "/v1/chat/completions", sent}
    assert [%{"content" => prompt, "role" => "user"}] = sent["messages"]
    assert prompt == continued_case.prompt
    assert sent["response_format"]["type"] == "json_schema"

    summary = RoutingReplay.summary([continued_case, quick_case], result, [])
    assert {summary.same, summary.changed, summary.not_answered} == {1, 0, 1}

    assert summary.by_action == %{
             "continue_episode" => %{total: 1, valid: 1, same: 1, changed_to: %{}},
             "quick_reply" => %{total: 1, valid: 0, same: 0, changed_to: %{}}
           }

    assert %{count: 2, median: median} = summary.latency_ms
    assert is_integer(median)
  end

  test "an answer that makes Ryker do the same passes, whatever its words",
       %{example: line, candidate: candidate} do
    {:ok, replay} = RoutingReplayCase.new(line)

    same =
      candidate
      |> continued()
      |> Map.put("reason", "Different words, same decision.")
      |> Jason.encode!()

    assert {:accept, %{passed: true}} = RoutingReplayCase.validate(replay, same)

    changed = Jason.encode!(quick_reply())

    assert {:accept, %{passed: false, document: document}} =
             RoutingReplayCase.validate(replay, changed)

    assert document == %{
             "action" => "quick_reply",
             "episode_ref" => nil,
             "relation" => "unrelated"
           }
  end

  # SE1a (2026-09-27): routing is asked how the sender feels about Ryker's
  # previous answer when a person's message follows one. No recorded context
  # holds previous_answer, so without reading it from the recorded
  # conversation a replay could never try the sentiment wording or contract.
  test "a person's message after one of Ryker's answers is asked about sentiment, and the report counts what was read",
       %{context: context, request: request, candidate: candidate, example: plain} do
    answered =
      put_in(request, ["context", "conversation_context"], %{
        "messages" => [
          %{
            "actor" => "UALICE",
            "at" => "2026-08-27T11:58:00Z",
            "text" => "Checkout returns 502"
          },
          %{"actor" => "ryker", "at" => "2026-08-27T11:59:30Z", "text" => "It is back now."}
        ]
      })

    {:ok, replay} = RoutingReplayCase.new(line(answered, context, continued(candidate)))
    assert replay.sentiment_offered
    assert replay.prompt =~ "previous_answer is when Ryker last answered here"
    assert replay.prompt =~ ~s("previous_answer":{"at":"2026-08-27T11:59:30Z"})
    assert Map.has_key?(replay.schema["properties"], "sentiment")

    felt =
      continued(candidate)
      |> Map.put("sentiment", %{
        "feeling" => "frustrated",
        "reason" => "They say it is still down."
      })

    assert {:accept, %{passed: true, document: %{"sentiment" => "frustrated"} = document}} =
             RoutingReplayCase.validate(replay, Jason.encode!(felt))

    # Without an answer before the message, nothing is asked about sentiment.
    {:ok, unanswered} = RoutingReplayCase.new(plain)
    refute unanswered.sentiment_offered
    refute Map.has_key?(unanswered.schema["properties"], "sentiment")
    refute unanswered.prompt =~ "previous_answer"

    results = [
      %{eval_id: replay.eval_id, status: :passed, decision: document},
      %{eval_id: unanswered.eval_id, status: :passed, decision: Map.delete(document, "sentiment")}
    ]

    summary = RoutingReplay.summary([replay, unanswered], %{results: results}, [])
    assert summary.sentiment == %{offered: 1, read: %{"frustrated" => 1}}
    assert summary.same == 2
  end

  test "an answer routing could not act on goes back for repair", %{example: line} do
    {:ok, replay} = RoutingReplayCase.new(line)

    assert {:reject, [_why]} = RoutingReplayCase.validate(replay, "not a decision")

    unknown = Jason.encode!(continued("episode:somewhere-else"))
    assert {:reject, [why]} = RoutingReplayCase.validate(replay, unknown)
    assert why =~ "one of the candidates"
  end

  test "the eval worker's answer is repaired in the same turn and a changed decision is named",
       %{example: line} do
    {:ok, replay} = RoutingReplayCase.new(line)
    {:ok, fake} = FakeCoopAPI.start_link(["not a decision", Jason.encode!(quick_reply())])

    assert {:ok, %{failed: 1, passed: 0} = result} = CoopRunner.run([replay], options(fake))
    assert Enum.map(FakeCoopAPI.state(fake).validations, & &1.verdict) == [:reject, :accept]

    summary = RoutingReplay.summary([replay], result, [])
    assert %{total: 1, same: 0, changed: 1, not_answered: 0} = summary
    assert summary.fields == %{"action" => 0, "episode_ref" => 0, "relation" => 0}

    assert [%{status: :changed, example_id: id, replayed: %{"action" => "quick_reply"}}] =
             summary.examples

    assert id == line["labels"]["example_id"]
    # The report names the example and the decisions, never what was said.
    refute inspect(summary) =~ "Still down?"
  end

  test "an export is read line by line, and what cannot be replayed is set aside with why",
       %{example: line} do
    path = Path.join(System.tmp_dir!(), "routing-replay-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)

    unanswered = put_in(line, ["messages", Access.at(1), "content"], "{}")

    File.write!(path, [
      Jason.encode!(line),
      "\n",
      "{not json\n",
      Jason.encode!(unanswered),
      "\n\n"
    ])

    assert {:ok, [replay], [%{line: 2}, %{line: 3}]} = RoutingReplay.cases(path)
    assert replay.labels["example_id"] == line["labels"]["example_id"]

    assert RoutingReplay.cases(path <> ".missing") ==
             {:error, {:routing_examples_not_found, path <> ".missing"}}
  end

  # One line of the routing examples export, as `Ryker.RoutingExamples.Export`
  # writes it, of a request made with yesterday's instructions.
  defp line(request, context, decision) do
    %{
      "messages" => [
        %{
          "role" => "user",
          "content" =>
            request |> Map.put("instructions", "Yesterday's wording.") |> Prompt.render()
        },
        %{"role" => "assistant", "content" => Jason.encode!(decision)}
      ],
      "output_schema" => schema(context),
      "labels" => %{
        "example_id" => Ecto.UUID.generate(),
        "request_ref" => "episode:checkout",
        "decided_at" => "2026-08-27T12:00:02Z",
        "model" => "codex:fixture/low@eval",
        "decision" => decision
      }
    }
  end

  defp schema(context) do
    Decision.json_schema(
      Input.allowed_actions(context.input),
      Input.reaction_names(context.input),
      false,
      []
    )
  end

  defp continued(episode_ref) do
    {:ok, decision} =
      Decision.parse(%{
        "action" => "continue_episode",
        "episode_ref" => episode_ref,
        "messages" => nil,
        "reactions" => nil,
        "reason" => "The same checkout outage.",
        "relation" => "same_work",
        "repository" => nil,
        "repository_source" => nil,
        "work_class" => "standard"
      })

    Decision.document(decision)
  end

  defp quick_reply do
    %{
      "action" => "quick_reply",
      "episode_ref" => nil,
      "messages" => ["Checking checkout now."],
      "reactions" => nil,
      "reason" => "A short answer is enough.",
      "relation" => "unrelated",
      "repository" => nil,
      "repository_source" => nil,
      "work_class" => nil
    }
  end

  defp local_model!(script) do
    {:ok, answers} = Agent.start_link(fn -> script end)
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

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

  defp options(fake) do
    [
      api: FakeCoopAPI,
      client: fake,
      id_generator: fn -> "routing-replay-run" end,
      max_polls: 4,
      job: elem(Job.new(:routing, "codex:fixture/low@eval"), 1),
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  defp context! do
    opening = %{
      occurred_at: ~U[2026-08-27 10:00:00.000000Z],
      payload: %{
        "payload" => %{
          "actor" => %{"kind" => "user", "ref" => "UALICE"},
          "content" => %{"text" => "Checkout returns 502"}
        }
      }
    }

    candidate =
      Candidate.new(%{
        allowed_relations: [:same_work, :history_only],
        digest: %{"conversations" => 1, "message_count" => 2, "title" => "Checkout 502s"},
        endpoints: %{first: opening, latest: opening},
        episode: %Episode{
          destination_thread_ref: "thread",
          id: "0f7d2b8e-3c1a-4c55-9a52-7a1c1e3e2b10",
          state: :running,
          updated_at: ~U[2026-08-27 11:30:00.000000Z]
        },
        idle_minutes: 30,
        match: %{},
        same_thread: true,
        source_owner: false
      })

    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "UALICE"},
        channel_ref: "C456",
        content: %{"text" => "Still down?"},
        event_kind: :message,
        event_ref: "Ev123",
        message_ref: "1787832000.000100",
        occurred_at: ~U[2026-08-27 12:00:00.000000Z],
        revision: 1,
        thread_ref: "thread",
        workspace_ref: "T123"
      })

    %Context{
      active_episode_fingerprint: Ryker.CanonicalJSON.digest([]),
      built_at: ~U[2026-08-27 12:00:01.000000Z],
      candidates: [candidate],
      conversation_episode_count: 1,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()}
    }
  end
end
