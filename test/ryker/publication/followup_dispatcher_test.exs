defmodule Ryker.Publication.FollowupDispatcherTest do
  use Ryker.DataCase, async: true

  alias Ryker.Delivery.Adapters
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.{FollowupDispatcher, LifecycleEvent}
  alias Ryker.Work.DeliveryReceipt

  defmodule StatusAPI do
    def get_publication_status(agent, repository, number) do
      Agent.get_and_update(agent, fn state ->
        send(state.observer, {:publication_status_requested, repository, number})
        {{:ok, state.status}, state}
      end)
    end
  end

  defmodule MessagePublisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher

    def transport, do: "slack"

    def publish_message(request, agent) do
      Agent.get_and_update(agent, fn state ->
        send(state.observer, {:publication_lifecycle_delivered, request})

        {:ok, receipt} =
          DeliveryReceipt.new(
            request.ref,
            request.transport,
            request.conversation_ref,
            request.thread_ref,
            "message:lifecycle:#{length(state.deliveries) + 1}"
          )

        {{:ok, receipt}, %{state | deliveries: state.deliveries ++ [request]}}
      end)
    end
  end

  defmodule ReactionPublisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.ReactionPublisher

    def transport, do: "slack"
    def publish_reaction(_request, _binding), do: {:error, :not_used}
  end

  defmodule FailingStatusAPI do
    def get_publication_status(_client, _repository, _number),
      do: {:error, :github_unavailable}
  end

  test "a due publication is polled and its lifecycle notice is delivered once" do
    %{publication: publication} = PublicationFixture.published!("followup-dispatcher")

    status = %{
      "base_ref" => "main",
      "checks_failed" => 0,
      "checks_passed" => 2,
      "checks_state" => "passing",
      "checks_total" => 2,
      "checks_url" => "#{publication.pull_request_url}/checks",
      "draft" => true,
      "head_ref" => String.replace_prefix(publication.branch_ref, "refs/heads/", ""),
      "head_sha" => publication.commit_sha,
      "merge_sha" => nil,
      "merged" => false,
      "merged_at" => nil,
      "number" => publication.pull_request_number,
      "state" => "open",
      "url" => publication.pull_request_url
    }

    observer = self()

    {:ok, effects} =
      Agent.start_link(fn -> %{deliveries: [], observer: observer, status: status} end)

    options = dispatcher_options(effects)

    assert {:ok, {:executed, %{phase: :poll}}} = FollowupDispatcher.run_once(options)

    assert_receive {:publication_status_requested, "acme/ryker", 91}

    assert %LifecycleEvent{delivery_state: :pending, kind: "checks", state: "succeeded"} =
             Repo.get_by!(LifecycleEvent, publication_id: publication.id, kind: "checks")

    assert {:ok, {:executed, %{phase: :delivery}}} = FollowupDispatcher.run_once(options)
    assert_receive {:publication_lifecycle_delivered, request}
    assert request.conversation_ref == publication.destination_conversation_ref
    assert request.thread_ref == publication.destination_thread_ref
    assert request.document["message"] =~ "GitHub checks passed"

    event = Repo.get_by!(LifecycleEvent, publication_id: publication.id, kind: "checks")
    assert event.delivery_state == :delivered
    assert Agent.get(effects, &length(&1.deliveries)) == 1
  end

  test "a transient poll failure releases custody with bounded retry state" do
    %{publication: publication} = PublicationFixture.published!("followup-defer")

    observer = self()

    {:ok, effects} =
      Agent.start_link(fn -> %{deliveries: [], observer: observer, status: %{}} end)

    options =
      dispatcher_options(effects)
      |> Keyword.update!(:executor_options, &Keyword.put(&1, :api, FailingStatusAPI))

    assert {:ok, {:deferred, :github_unavailable}} = FollowupDispatcher.run_once(options)

    followup = Repo.get_by!(Ryker.Publication.Followup, publication_id: publication.id)
    assert followup.failure_count == 1
    assert followup.lease_ref == nil
    assert followup.next_poll_at != nil
  end

  defp dispatcher_options(effects) do
    {:ok, adapters} =
      Adapters.new(%{
        "slack" => %{
          binding: effects,
          message_publisher: MessagePublisher,
          reaction_publisher: ReactionPublisher
        }
      })

    [
      executor_options: [adapters: adapters, api: StatusAPI, client: effects],
      interval_seconds: 120,
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "publication-followup:test"
    ]
  end
end
