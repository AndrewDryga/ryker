defmodule Ryker.Publication.RuntimeTest do
  use Ryker.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ryker.Publication.{FollowupWorker, Runtime, Worker}

  defmodule StatusAPI do
    def get_publication_status(_client, _repository, _number), do: {:error, :not_used}
  end

  defmodule ReviewAPI do
    def get_session(_client, _session_id), do: {:error, :not_used}
    def publish_review(_, _, _, _, _, _), do: {:error, :not_used}
    def run_review(_client, _session_id, _key, _revision), do: {:error, :not_used}
  end

  defmodule MessagePublisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher

    def transport, do: "slack"
    def publish_message(_request, _binding), do: {:error, :not_used}
  end

  defmodule ReactionPublisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.ReactionPublisher

    def transport, do: "slack"
    def publish_reaction(_request, _binding), do: {:error, :not_used}
  end

  test "runtime supervises the configured bounded publication pool" do
    options = Runtime.options!(configuration())
    assert options.concurrency == 2
    assert options.worker_ref == "publication-worker:test"
    assert options.status_api == StatusAPI
    assert options.status_client == :status_client
    assert options.coop_api == ReviewAPI
    assert options.coop_client == :coop_client

    assert %{id: Runtime, type: :supervisor} = Runtime.child_spec(configuration())

    {:ok, supervisor} = start_supervised({Runtime, configuration()})
    children = Supervisor.which_children(supervisor)

    assert length(children) == 3
    assert Enum.count(children, fn {id, _, _, _} -> match?({Worker, _}, id) end) == 2
    assert Enum.any?(children, fn {id, _, _, _} -> id == FollowupWorker end)
    assert Enum.all?(children, fn {_id, pid, _type, _modules} -> Process.alive?(pid) end)
  end

  test "standalone workers keep polling an idle queue and surface invalid dispatchers" do
    {:ok, publication_worker} =
      start_supervised(
        {Worker,
         name: :publication_idle_worker,
         dispatcher_options: [worker_ref: "publication:test"],
         poll_interval_ms: 10}
      )

    {:ok, followup_worker} =
      start_supervised(
        {FollowupWorker,
         dispatcher_options: [worker_ref: "publication-followup:test"], poll_interval_ms: 10}
      )

    Process.sleep(5)
    assert Process.alive?(publication_worker)
    assert Process.alive?(followup_worker)

    assert capture_log(fn ->
             {:ok, invalid_worker} =
               Worker.start_link(
                 dispatcher_options: [],
                 poll_interval_ms: 10
               )

             Process.sleep(5)
             GenServer.stop(invalid_worker)
           end) =~ "publication dispatcher failed"

    assert capture_log(fn ->
             {:ok, invalid_worker} =
               FollowupWorker.start_link(
                 dispatcher_options: [],
                 poll_interval_ms: 10
               )

             Process.sleep(5)
             GenServer.stop(invalid_worker)
           end) =~ "publication followup dispatcher failed"

    assert Worker.init(poll_interval_ms: 0, dispatcher_options: []) ==
             {:stop, {:invalid_publication_worker, :options}}

    assert FollowupWorker.init(poll_interval_ms: 0, dispatcher_options: []) ==
             {:stop, {:invalid_publication_followup_worker, :options}}
  end

  test "runtime refuses unsafe or ambiguous publication authority" do
    invalid = [
      :invalid,
      [],
      [worker_ref: "one", worker_ref: "two"],
      Map.delete(configuration(), :repositories),
      Map.put(configuration(), :unknown, true),
      %{configuration() | concurrency: 17},
      %{configuration() | repositories: []},
      %{configuration() | worker_ref: ""},
      %{configuration() | status_api: String},
      Map.delete(configuration(), :status_client),
      %{configuration() | delivery_adapters: %{}},
      %{configuration() | coop_api: StatusAPI}
    ]

    Enum.each(invalid, fn configuration ->
      assert_raise ArgumentError, fn -> Runtime.options!(configuration) end
    end)
  end

  test "publication starts only on an explicit Coop adapter, never a local socket" do
    # Product builds review and publish work through the enrolled worker fleet.
    # The local Unix-socket client a `socket` used to build is eval-only and
    # left the release, so a configuration naming a socket, or no adapter at
    # all, must stop before supervision rather than at its first Coop call.
    adapterless = Map.drop(configuration(), [:coop_api, :coop_client])

    for invalid <- [
          Map.put(adapterless, :socket, "/tmp/coop-publication-test.sock"),
          adapterless,
          Map.put(adapterless, :coop_api, ReviewAPI),
          %{configuration() | coop_client: nil},
          %{configuration() | coop_api: nil}
        ] do
      assert_raise ArgumentError, fn -> Runtime.options!(invalid) end
    end
  end

  defp configuration do
    %{
      concurrency: 2,
      coop_api: ReviewAPI,
      coop_client: :coop_client,
      delivery_adapters: %{
        "slack" => %{
          binding: :delivery_client,
          message_publisher: MessagePublisher,
          reaction_publisher: ReactionPublisher
        }
      },
      followup_interval_seconds: 30,
      lease_seconds: 60,
      poll_interval_ms: 20,
      repositories: %{},
      status_api: StatusAPI,
      status_client: :status_client,
      retry_base_seconds: 1,
      retry_max_seconds: 30,
      worker_ref: "publication-worker:test"
    }
  end
end
