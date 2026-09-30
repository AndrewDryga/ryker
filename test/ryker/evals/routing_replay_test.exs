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
