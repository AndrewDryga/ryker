defmodule Responder.Slack.ArtifactEndToEndTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Artifacts.Outputs
  alias Responder.Delivery.{Adapters, Dispatcher}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Slack.Publisher
  alias Responder.TestSupport.FakeWorkCoopAPI
  alias Responder.Work.{Custody, Executor, Turn}

  @now ~U[2026-08-31 12:00:00.000000Z]
  @old ~U[2020-01-01 00:00:00.000000Z]
  @policy_digest String.duplicate("a", 64)
  @png <<137, 80, 78, 71, 13, 10, 26, 10, "generated-latency-chart">>

  defmodule SlackAPI do
    @behaviour Responder.Slack.API

    def start_link(test_pid) do
      Agent.start_link(fn ->
        %{
          file_finds: 0,
          files: %{},
          lose_upload_response: true,
          test_pid: test_pid,
          uploads: []
        }
      end)
    end

    def state(agent), do: Agent.get(agent, & &1)

    @impl true
    def find_message(_client, _channel, _thread, _delivery_ref), do: :not_found

    @impl true
    def post_message(_client, _channel, _thread, _document, _delivery_ref),
      do: {:error, :not_used}

    @impl true
    def update_message(_client, _channel, _message_ref, _document, _delivery_ref), do: :ok

    @impl true
    def find_files(agent, channel, thread, filenames) do
      Agent.get_and_update(agent, fn state ->
        result = Map.get(state.files, {channel, thread, filenames}, :not_found)
        {result, %{state | file_finds: state.file_finds + 1}}
      end)
    end

    @impl true
    def upload_files(agent, channel, thread, document, delivery_ref, files) do
      Agent.get_and_update(agent, fn state ->
        filenames = Enum.map(files, & &1.filename)
        key = {channel, thread, filenames}
        message_ref = "1788265001.000200"

        send(state.test_pid, {:uploaded, channel, thread, document, delivery_ref, files})

        next = %{
          state
          | files: Map.put(state.files, key, {:ok, message_ref}),
            uploads: state.uploads ++ [{channel, thread, document, delivery_ref, files}]
        }

        if state.lose_upload_response do
          {{:error, :socket_closed}, %{next | lose_upload_response: false}}
        else
          {{:ok, message_ref}, next}
        end
      end)
    end

    @impl true
    def add_reaction(_client, _channel, _message_ref, _emoji_name), do: {:error, :not_used}
  end

  test "a lost Slack artifact response reconciles one verified Coop image exactly once" do
    claim = claim_episode!()
    sha256 = digest(@png)
    artifact_ref = "artifact_#{binary_part(sha256, 0, 24)}"

    metadata = %{
      "bytes" => byte_size(@png),
      "id" => artifact_ref,
      "media_type" => "image/png",
      "name" => "latency chart.png",
      "sha256" => sha256
    }

    remote = Map.put(metadata, "data", @png)

    {:ok, work_api} =
      FakeWorkCoopAPI.start_link([artifact_reply(artifact_ref)],
        output_artifact_metadata: [metadata],
        output_artifacts: %{artifact_ref => remote}
      )

    assert {:ok, accepted} = Executor.run(claim, executor_options(work_api))
    assert accepted.turn.status == :delivery_pending

    assert {:ok, [stored]} = Outputs.fetch_many(accepted.turn.id, [artifact_ref])
    assert stored.data == @png
    assert stored.sha256 == sha256

    {:ok, slack_api} = SlackAPI.start_link(self())
    adapters = adapters!(slack_api)

    assert {:ok, {:deferred, :message, delivery_ref, {:delivery_uncertain, :socket_closed}}} =
             deliver_once(adapters, "lost")

    assert delivery_ref == accepted.turn.delivery_ref

    assert_receive {
      :uploaded,
      "C456",
      "1788265000.000100",
      %{"message" => "The latency chart is attached."},
      ^delivery_ref,
      [file]
    }

    assert file.data == @png
    assert file.media_type == "image/png"
    assert file.title == "latency chart.png"
    assert file.filename =~ ~r/\Alatency-chart--[0-9a-f]{12}-01\.png\z/

    Repo.update_all(
      from(turn in Turn, where: turn.id == ^accepted.turn.id),
      set: [next_attempt_at: @old]
    )

    assert {:ok, {:delivered, :message, ^delivery_ref}} = deliver_once(adapters, "reconcile")

    state = SlackAPI.state(slack_api)
    assert state.file_finds == 2
    assert length(state.uploads) == 1
    refute_receive {:uploaded, _, _, _, _, _}

    assert %Turn{status: :settled, external_receipt: receipt} =
             Repo.get!(Turn, accepted.turn.id)

    assert receipt["delivery_ref"] == delivery_ref
    assert receipt["message_ref"] == "1788265001.000200"
    assert receipt["conversation_ref"] == "slack:T123:C456"
    assert receipt["thread_ref"] == "1788265000.000100"
  end

  defp claim_episode! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: %{
                   conversation_ref: "slack:T123:C456",
                   thread_ref: "1788265000.000100",
                   transport: "slack"
                 },
                 episode_id: episode_id,
                 episode_key: "artifact-e2e:#{episode_id}",
                 native_input_id: "slack-message:artifact-e2e:#{episode_id}",
                 occurred_at: @now,
                 payload: %{"text" => "Generate and attach the latency chart."},
                 turn_ref: "turn:artifact-e2e:#{episode_id}"
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "conversation-read-only", @policy_digest)

    assert {:ok, claim} = Custody.claim_next("artifact-e2e-work", 60, :work)
    claim
  end

  defp adapters!(slack_api) do
    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"T123" => %{api: SlackAPI, client: slack_api}}},
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    adapters
  end

  defp deliver_once(adapters, suffix) do
    Dispatcher.run_once(
      adapters: adapters,
      kind: :message,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "artifact-e2e-delivery-#{suffix}"
    )
  end

  defp executor_options(api) do
    [
      api: FakeWorkCoopAPI,
      client: api,
      max_block_ms: 1_000,
      max_polls: 20,
      monotonic_ms: fn -> 0 end,
      now: fn -> @now end,
      poll_interval_ms: 0,
      sleep: fn _milliseconds -> :ok end
    ]
  end

  defp artifact_reply(artifact_ref) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => "The latency chart is attached.",
      "outcome" => %{
        "artifact_refs" => [artifact_ref],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end

  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
