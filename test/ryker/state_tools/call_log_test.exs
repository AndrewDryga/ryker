defmodule Ryker.StateTools.CallLogTest do
  # Reads the episode page projection, which starts the globally named
  # Names cache, so it cannot share the VM with other running suites.
  use Ryker.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  import Plug.Test
  import Phoenix.LiveViewTest

  alias Ryker.ControlPlane.{Projection, ToolCard}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Slack.Names
  alias Ryker.State.Records
  alias Ryker.StateTools.{CallLog, ErrorCode, Router}
  alias Ryker.Work.{Activity, Custody, Turn}

  @token "trusted-state-tools-token"
  @remote_turn "turn_5d45d1dae4a96ff6587d4b28b7de45a0"

  test "a refused state tool shows the error Ryker answered and the arguments it was sent" do
    # 2026-09-25: a weekday schedule failed four times in one conversation and
    # every timeline row said "Its error response was not recorded for this
    # older call" above arguments that named only the server and the tool, so
    # nobody could tell why propose_automation refused, seconds after it did.
    # Coop's worker never sends either; Ryker, which answered the call, keeps both.
    work = bound_turn!("weekday-refusal")

    before_call = DateTime.utc_now()
    answer = call_tool(work, "propose_automation", %{"proposals" => weekday_bundle()})
    after_call = DateTime.utc_now()
    assert answer["isError"]

    # The narration Coop recorded for the first refusal in production, as it
    # crossed the worker's privacy boundary: no arguments and no error body.
    assert {:ok, %{inserted: 2}} =
             Activity.ingest(work.session.id, [
               coop_event(work, 1, "tool.started", DateTime.add(before_call, -3, :millisecond), %{
                 "input" => %{"server" => "responder-state", "tool" => "propose_automation"},
                 "kind" => "execute",
                 "tool_call_id" => "exec-fecaf7f6-0788-49ad-8cd5-3fc6a3d5ae08"
               }),
               coop_event(work, 2, "tool.completed", DateTime.add(after_call, 4, :millisecond), %{
                 "kind" => "execute",
                 "status" => "failed",
                 "tool_call_id" => "exec-fecaf7f6-0788-49ad-8cd5-3fc6a3d5ae08"
               })
             ])

    {:ok, detail} = Projection.episode(work.episode.key)
    step = Enum.find(detail.trace.steps, &(&1[:stage] == "Tool call"))

    assert step.state == "failed"

    assert step.summary ==
             "Ryker rejected the call because its arguments did not match what the tool accepts."

    html = render_component(&ToolCard.render/1, step: step)
    refute html =~ "older call"
    assert html =~ "Propose an automation"
    assert html =~ "Weekday status (friday)"

    error = Enum.find(step.artifacts, &(&1.label == "Error"))
    assert error.artifact.state == :collapsed

    {:ok, opened} =
      Projection.episode(work.episode.key, %{"disclosed" => [error.artifact_id]})

    opened_step = Enum.find(opened.trace.steps, &(&1.id == step.id))
    opened_error = Enum.find(opened_step.artifacts, &(&1.label == "Error"))
    assert opened_error.artifact.text =~ "invalid_arguments"
  end

  # On 2026-09-26 every memory search raised inside Ryker (an invalid query in
  # the retained-cases lane). The request crashed with HTTP 500 before the call
  # was recorded, so the model said earlier saved context could not be checked
  # and the timeline could only say Ryker had no record of the call. A raise is
  # Ryker's own error: the call is answered, recorded and logged.
  test "a tool that raises answers the call, records it and names the raise in the log" do
    work = bound_turn!("raising-tool")

    tool = %{
      "description" => "A lookup that raises.",
      "inputSchema" => %{
        "additionalProperties" => false,
        "properties" => %{"query" => %{"type" => "string"}},
        "required" => ["query"],
        "type" => "object"
      },
      "name" => "raising.lookup"
    }

    options =
      Router.init(
        token: @token,
        binding: %{
          episode: work.episode,
          session: work.session,
          state_token: Records.token(work.turn),
          turn: work.turn
        },
        additional_tools: [tool],
        additional_call: fn _name, _arguments, _binding -> raise "invalid query" end
      )

    body = %{
      "id" => 7,
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{"arguments" => %{"query" => "checkout"}, "name" => "raising.lookup"}
    }

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn =
          conn(:post, "/mcp", Jason.encode!(body))
          |> put_req_header("authorization", "Bearer " <> @token)
          |> put_req_header("content-type", "application/json")
          |> Router.call(options)

        assert conn.status == 200
        result = conn.resp_body |> Jason.decode!() |> Map.fetch!("result")
        assert result["isError"]
        assert result["structuredContent"] == %{"error" => "internal_error"}
      end)

    assert log =~ "raising.lookup"
    assert log =~ "invalid query"

    assert [%{status: "failed", tool: "raising.lookup"} = call] =
             CallLog.list_for_episode(work.episode.id)

    assert call.error == "internal_error"

    assert ErrorCode.explain("internal_error") =~
             "Ryker hit an error of its own"
  end

  test "a failure without an error body says why there is none instead of calling it older" do
    # The same QA pass read "not recorded for this older call" under a Read
    # file that had failed a second earlier. Coop never sends a tool's error
    # output, so that sentence was false for every call it narrated; it stays
    # only for a state-tool call made before Ryker recorded them.
    work = bound_turn!("unexplained-failures")
    now = DateTime.utc_now()
    later = DateTime.add(now, 40, :second)

    assert {:ok, %{inserted: 4}} =
             Activity.ingest(work.session.id, [
               coop_event(work, 1, "tool.started", now, %{
                 "kind" => "read",
                 "tool_call_id" => "exec-read"
               }),
               coop_event(work, 2, "tool.completed", DateTime.add(now, 1, :millisecond), %{
                 "kind" => "read",
                 "status" => "failed",
                 "tool_call_id" => "exec-read"
               }),
               coop_event(work, 3, "tool.started", later, %{
                 "input" => %{"server" => "responder-state", "tool" => "propose_automation"},
                 "kind" => "execute",
                 "tool_call_id" => "exec-proposal"
               }),
               coop_event(work, 4, "tool.completed", DateTime.add(later, 5, :millisecond), %{
                 "kind" => "execute",
                 "status" => "failed",
                 "tool_call_id" => "exec-proposal"
               })
             ])

    assert failed_summaries(work) == %{
             "exec-read" =>
               "The tool failed. The worker does not send tool error details to Ryker.",
             "exec-proposal" =>
               "The tool failed. Its error response was not recorded for this older call."
           }

    # Once the turn has recordings, a call with none inside its window is one
    # Ryker never received, not an older one. The recording made now belongs
    # to a call forty seconds earlier and is not handed to this one.
    listed_at = DateTime.utc_now()

    refute call_tool(work, "list_automations", %{"limit" => 20, "relationship" => "either"})[
             "isError"
           ]

    assert {:ok, %{inserted: 2}} =
             Activity.ingest(work.session.id, [
               coop_event(work, 5, "tool.started", DateTime.add(listed_at, -2, :millisecond), %{
                 "input" => %{"server" => "responder-state", "tool" => "list_automations"},
                 "kind" => "execute",
                 "tool_call_id" => "exec-list"
               }),
               coop_event(work, 6, "tool.completed", DateTime.utc_now(), %{
                 "kind" => "execute",
                 "status" => "failed",
                 "tool_call_id" => "exec-list"
               })
             ])

    assert %{
             "exec-proposal" =>
               "The tool failed, and Ryker has no record of receiving the call, so there is no error response to show.",
             "exec-list" => "Ryker answered the call, but the worker reported it as failed."
           } = failed_summaries(work)
  end

  defp failed_summaries(work) do
    {:ok, detail} = Projection.episode(work.episode.key)

    for step <- detail.trace.steps,
        step[:stage] == "Tool call" and step.state == "failed",
        into: %{} do
      call_id = Enum.find_value(step.details, &(&1.label == "Tool call" && &1.value))

      {call_id, step.summary}
    end
  end

  defp bound_turn!(suffix) do
    {:ok, started} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: Ecto.UUID.generate(),
          episode_key: "call-log:#{suffix}",
          native_input_id: "call-log-input:#{suffix}",
          turn_ref: "call-log-turn:#{suffix}"
        })
      )

    {:ok, session} =
      Custody.pin_episode(started.episode.id, "policy:call-log", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("call-log:#{suffix}", 60, :work)

    {:ok, session} =
      Custody.bind_session(
        started.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        session.create_generation,
        "remote:call-log:#{suffix}"
      )

    {1, _} =
      Repo.update_all(from(turn in Turn, where: turn.id == ^claim.turn.id),
        set: [coop_turn_id: @remote_turn]
      )

    %{episode: claim.episode, session: session, turn: Repo.get!(Turn, claim.turn.id)}
  end

  defp call_tool(work, name, arguments) do
    options =
      Router.init(
        token: @token,
        binding: %{
          episode: work.episode,
          session: work.session,
          state_token: Records.token(work.turn),
          turn: work.turn
        }
      )

    body = %{
      "id" => 1,
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{"arguments" => arguments, "name" => name}
    }

    conn =
      conn(:post, "/mcp", Jason.encode!(body))
      |> put_req_header("authorization", "Bearer " <> @token)
      |> put_req_header("content-type", "application/json")
      |> Router.call(options)

    conn.resp_body |> Jason.decode!() |> Map.fetch!("result")
  end

  # Five weekly proposals, one per weekday: what the model sent for "every
  # weekday at 9:00". A proposal set holds at most four.
  defp weekday_bundle do
    for weekday <- ~w(monday tuesday wednesday thursday friday) do
      %{
        "action" => "create",
        "patch" => %{},
        "prompt" => "Post a one-line status of open incidents here.",
        "repository" => nil,
        "title" => "Weekday status (#{weekday})",
        "trigger" => %{
          "recurrence" => "weekly",
          "time" => "09:00",
          "timezone" => "UTC",
          "type" => "time",
          "weekday" => weekday
        }
      }
    end
  end

  defp coop_event(work, sequence, type, at, payload) do
    %{
      "id" => "call-log-event-#{sequence}",
      "occurred_at" => DateTime.to_iso8601(at),
      "payload" => payload,
      "sequence" => sequence,
      "session_id" => work.session.coop_session_id,
      "turn_id" => @remote_turn,
      "type" => type,
      "version" => 1
    }
  end
end
