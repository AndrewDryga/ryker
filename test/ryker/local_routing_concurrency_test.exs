defmodule Ryker.LocalRoutingConcurrencyTest do
  @moduledoc """
  A person deleting their message races the local routing model being asked
  about a prompt that quotes it.

  Routing's commit queues the comparison, and a deletion erases every
  comparison it finds. When the two land together, the deletion can look
  before routing's commit makes the comparison visible and find none. The
  lane then took the comparison and checked the message while the deletion
  was still committing, found it there, sent its prompt to the local model
  and kept the answer, for as long as the message's bodies were kept (found
  in review, 2026-09-28).

  These commit for real, on connections of their own, and remove what they
  wrote.
  """
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Admission
  alias Ryker.Admission.{Attempt, Context, Decision, Prompt}
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Fixtures.LocalRouting, as: Harvested
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.Observations
  alias Ryker.LocalRouting
  alias Ryker.LocalRouting.Comparison
  alias Ryker.Repo
  alias Ryker.RoutingExamples
  alias Ryker.Slack.ChannelMembership
  alias Ryker.Slack.Input, as: SlackInput

  @workspace "TLOCALRACE"
  @channel "CLOCALRACE"
  @model "qwen2.5:3b"

  defmodule LocalModel do
    @moduledoc false
    @behaviour Plug
    import Plug.Conn
    alias Ryker.Fixtures.LocalRouting, as: Harvested

    @impl true
    def init(test), do: test

    # Answers every request with a real local answer, and tells the test
    # what it was asked.
    @impl true
    def call(conn, test) do
      {:ok, body, conn} = read_body(conn, length: 4_000_000)
      send(test, {:local_request, Jason.decode!(body)})

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        200,
        Jason.encode!(%{
          "choices" => [
            %{
              "finish_reason" => "stop",
              "index" => 0,
              "message" => %{
                "content" => Harvested.hi_again_quick_reply(),
                "role" => "assistant"
              }
            }
          ],
          "model" => "qwen2.5:3b",
          "usage" => %{"completion_tokens" => 58, "prompt_tokens" => 4_213}
        })
      )
    end
  end

  test "a message deleted while its comparison is taken is never sent, and no answer to it is kept" do
    Sandbox.unboxed_run(Repo, fn ->
      message_ref = unique_message_ref()
      endpoint = local_model!()

      try do
        entry = routed!(message_ref)
        parent = self()

        # The deletion erases the comparisons it finds, before routing's
        # commit has made this one visible, and is still committing.
        deleter =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              assert {:ok, %{status: :recorded}} = Inbox.record(deletion!(message_ref))
              send(parent, {:deletion_open, backend_pid()})

              receive do
                :commit -> :ok
              after
                5_000 -> :ok
              end
            end)
          end)

        assert_receive {:deletion_open, deleter_backend}, 5_000
        queued!(entry)

        lane =
          unboxed_task(fn ->
            send(parent, {:lane_ready, backend_pid()})
            LocalRouting.run_next(options(endpoint))
          end)

        assert_receive {:lane_ready, lane_backend}, 5_000

        try do
          await_finished_or_blocked(lane, lane_backend, deleter_backend)
          send(deleter.pid, :commit)
          assert Task.await(deleter, 5_000) == {:ok, :ok}
          assert {:ran, _comparison} = Task.await(lane, 5_000)

          refute Repo.get_by(Comparison, input_id: entry.id),
                 "the local model's answer about a message deleted while it was asked is kept"

          refute_received {:local_request, _request},
                          "the local model was sent the prompt of a message being deleted"
        after
          stop_tasks([deleter, lane])
        end
      after
        clean!(message_ref)
      end
    end)
  end

  # A person's greeting, routed as routing commits a decision: the context
  # frozen beside it, the prompt and contract the provider was sent, and the
  # provider's real answer.
  defp routed!(message_ref) do
    assert {:ok, %{entry: entry}} = Inbox.record(message!(message_ref))
    input_ref = Inbox.ref(entry)

    assert {:ok, context} =
             Admission.context(input_ref,
               now: DateTime.utc_now(),
               continuation_window: 1_800,
               history_window: 2_592_000,
               candidate_limit: 8
             )

    snapshot = Context.snapshot(context)

    Repo.update_all(from(input in Entry, where: input.id == ^entry.id),
      set: [
        admission_context: snapshot,
        admission_context_fingerprint: CanonicalJSON.digest(snapshot)
      ]
    )

    submission = %{
      "prompt" => context |> Prompt.build() |> Prompt.render(),
      "output_schema" =>
        Decision.json_schema(
          Input.allowed_actions(context.input),
          Input.reaction_names(context.input),
          false,
          []
        )
    }

    Repo.insert!(%Attempt{
      input_id: entry.id,
      generation: entry.execution_generation,
      policy: "admission-read-only",
      policy_digest: String.duplicate("a", 64),
      submission: submission,
      submission_fingerprint: CanonicalJSON.digest(submission),
      execution_target: Harvested.provider_target(),
      phase: "committed",
      response: %{"assistant_message" => Harvested.hi_quick_reply(), "state" => "completed"}
    })

    assert {:ok, decision} = Decision.parse(Jason.decode!(Harvested.hi_quick_reply()))
    assert {:ok, %{entry: decided}} = Admission.commit(context, decision, "decision:#{entry.id}")
    decided
  end

  # The comparison routing's commit queues while the local routing model is
  # in shadow (`Ryker.LocalRouting.queue_in_transaction/1`).
  defp queued!(entry) do
    quoted = RoutingExamples.quoted_keys(entry)

    Repo.insert!(%Comparison{
      input_id: entry.id,
      generation: entry.execution_generation,
      execution_mode: entry.execution_mode,
      status: :pending,
      attempt_count: 0,
      local_model: @model,
      source_identity: Observations.source_identity(entry),
      message_keys: quoted.keys,
      conversation_refs: quoted.conversations
    })
  end

  defp local_model! do
    port = unused_port!()

    start_supervised!(
      Bandit.child_spec(
        ip: {127, 0, 0, 1},
        plug: {LocalModel, self()},
        port: port,
        startup_log: false
      )
    )

    "http://127.0.0.1:#{port}/v1"
  end

  defp options(endpoint) do
    [
      endpoint: endpoint,
      model: @model,
      timeout_ms: 5_000,
      max_attempts: 4,
      retry_base_seconds: 30,
      retry_max_seconds: 600
    ]
  end

  defp message!(message_ref), do: slack_input!(message_ref, :message, Harvested.hi_text(), 1)
  defp deletion!(message_ref), do: slack_input!(message_ref, :delete, "", 2)

  defp slack_input!(message_ref, kind, text, revision) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :user, ref: "ULOCALRACE"},
               channel_ref: @channel,
               content: %{"text" => text},
               event_kind: kind,
               event_ref: "Ev-local-race-#{kind}-#{message_ref}",
               message_ref: message_ref,
               occurred_at: DateTime.add(DateTime.utc_now(), revision * 60 - 300, :second),
               revision: revision,
               thread_ref: nil,
               workspace_ref: @workspace
             })

    input
  end

  defp unique_message_ref,
    do: "1790300000." <> String.pad_leading("#{System.unique_integer([:positive])}", 6, "0")

  defp unused_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp clean!(message_ref) do
    entries =
      from(entry in Entry,
        where: entry.source_ref == @workspace and entry.source_item_ref == ^message_ref
      )

    ids = Repo.all(from(entry in entries, select: entry.id))
    Repo.delete_all(from(response in RoutingResponse, where: response.input_id in ^ids))
    delete_entries!(entries)
    Repo.delete_all(from(m in ChannelMembership, where: m.workspace_ref == @workspace))
  end
end
