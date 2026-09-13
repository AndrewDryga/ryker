defmodule Ryker.Webhooks.EndToEndTest do
  use Ryker.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query
  import Plug.Conn
  import Plug.Test

  alias Ryker.Admission.Dispatcher, as: AdmissionDispatcher
  alias Ryker.ControlPlane.{ConversationLab, Projection, Publisher}
  alias Ryker.Delivery.Adapters
  alias Ryker.Episodes
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.{Followup, LifecycleEvent}
  alias Ryker.Repo
  alias Ryker.Slack.Publisher, as: SlackPublisher
  alias Ryker.TestSupport.{FakeCoopAPI, FakeWorkCoopAPI}
  alias Ryker.Webhooks.{Route, Router}
  alias Ryker.Work.{Dispatcher, Final, Session, Turn}

  @now ~U[2026-08-27 12:00:00.000000Z]
  @old ~U[2020-01-01 00:00:00.000000Z]
  @secret "a-secret-token-long-enough"

  defmodule SlackAPI do
    @behaviour Ryker.Slack.API

    def start_link(observer) do
      Agent.start_link(fn ->
        %{finds: 0, message: nil, observer: observer, posts: 0}
      end)
    end

    def state(agent), do: Agent.get(agent, & &1)

    @impl true
    def find_message(agent, channel, thread, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        result =
          case state.message do
            {^channel, ^thread, ^delivery_ref, message_ref} -> {:ok, message_ref}
            _missing -> :not_found
          end

        {result, %{state | finds: state.finds + 1}}
      end)
    end

    @impl true
    def post_message(agent, channel, thread, document, delivery_ref) do
      Agent.get_and_update(agent, fn state ->
        message_ref = "1787832002.000300"
        send(state.observer, {:slack_posted, channel, thread, document, delivery_ref})

        {{:error, :socket_closed},
         %{
           state
           | message: {channel, thread, delivery_ref, message_ref},
             posts: state.posts + 1
         }}
      end)
    end

    @impl true
    def update_message(_client, _channel, _message_ref, _document, _delivery_ref),
      do: {:error, :not_used}

    @impl true
    def find_files(_client, _channel, _thread, _filenames), do: :not_found

    @impl true
    def upload_files(_client, _channel, _thread, _body, _delivery_ref, _files),
      do: {:error, :not_used}

    @impl true
    def add_reaction(_client, _channel, _message_ref, _emoji_name), do: {:error, :not_used}
  end

  test "an unknown authenticated webhook reaches validated work and a durable delivery intent" do
    body = Jason.encode!(%{"vendor_we_have_never_seen" => %{"severity" => 17, "state" => "odd"}})

    first = post(body, "vendor-occurrence-123")
    retry = post(body, "vendor-occurrence-123")

    assert first.status == 202
    assert retry.status == 202
    assert Jason.decode!(retry.resp_body)["status"] == "duplicate"

    {:ok, fake} = FakeCoopAPI.start_link([decision("start_episode")])

    assert {:ok, {:decided, execution}} =
             AdmissionDispatcher.run_once(admission_dispatcher_options(fake))

    assert execution.result.entry.source_kind == "webhook"
    assert execution.result.entry.decision_action == :start_episode
    assert execution.result.episode.destination_conversation_ref == "slack:T6E06DA3564B2:C456"

    assert [event] = Episodes.list_events(execution.result.episode.key)
    assert event.payload["payload"]["content"]["payload"] == Jason.decode!(body)

    assert %Session{
             policy: "webhook-conversation-read",
             policy_digest: digest,
             repository_ref: "ryker"
           } =
             Repo.get_by!(Session, episode_id: execution.result.episode.id)

    assert digest == String.duplicate("a", 64)

    {:ok, work_fake} =
      FakeWorkCoopAPI.start_link([
        work_reply("The unknown vendor event was accepted for investigation.")
      ])

    assert {:ok, {:executed, work_execution}} =
             Dispatcher.run_once(work_dispatcher_options(work_fake))

    assert work_execution.status == :accepted
    assert work_execution.turn.status == :delivery_pending
    assert %Turn{status: :delivery_pending} = Repo.get!(Turn, work_execution.turn.id)

    assert [submitted] = FakeWorkCoopAPI.state(work_fake).submissions
    assert submitted.schema == Final.json_schema()

    assert [work_input] = work_execution.turn.submission["context"]["inputs"]["items"]
    assert work_input["content"]["content"]["payload"] == Jason.decode!(body)

    {:ok, slack} = SlackAPI.start_link(self())

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: %{workspaces: %{"T6E06DA3564B2" => %{api: SlackAPI, client: slack}}},
                 message_publisher: SlackPublisher,
                 reaction_publisher: SlackPublisher
               }
             })

    assert {:ok, {:deferred, :message, delivery_ref, {:delivery_uncertain, :socket_closed}}} =
             Ryker.Delivery.Dispatcher.run_once(
               adapters: adapters,
               kind: :message,
               lease_seconds: 60,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "webhook-delivery-e2e:test"
             )

    assert_receive {
      :slack_posted,
      "C456",
      nil,
      %{"message" => "The unknown vendor event was accepted for investigation."},
      ^delivery_ref
    }

    Repo.update_all(
      from(turn in Turn, where: turn.id == ^work_execution.turn.id),
      set: [next_attempt_at: @old]
    )

    assert {:ok, {:delivered, :message, ^delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(
               adapters: adapters,
               kind: :message,
               lease_seconds: 60,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "webhook-delivery-e2e:reconcile"
             )

    assert %{finds: 2, posts: 1} = SlackAPI.state(slack)
    refute_receive {:slack_posted, _, _, _, _}

    assert %Turn{status: :settled, external_receipt: receipt} =
             Repo.get!(Turn, work_execution.turn.id)

    assert receipt["transport"] == "slack"
    assert receipt["conversation_ref"] == "slack:T6E06DA3564B2:C456"
    assert receipt["thread_ref"] == nil

    assert {:ok, :idle} =
             AdmissionDispatcher.run_once(admission_dispatcher_options(fake))

    assert FakeCoopAPI.state(fake).submit_count == 1
    assert FakeWorkCoopAPI.state(work_fake).submit_count == 1
  end

  test "an arbitrary signed webhook can exercise the full product through Conversation Lab without Slack traffic" do
    conversation_id = "018f3ef7-1f62-7ee0-a83c-0c12f21d83e6"
    assert {:ok, conversation_ref} = ConversationLab.conversation_ref(conversation_id)

    body =
      Jason.encode!(%{
        "kind" => "manual-lab-acceptance",
        "message" => "Universal adapter reaches Conversation Lab",
        "nested" => %{
          "arbitrary" => true,
          "count" => 3,
          "must_not_render" => "private-webhook-payload-marker"
        }
      })

    response = post_to_lab(body, "lab-webhook-occurrence", conversation_ref)
    assert response.status == 202

    {:ok, admission_fake} = FakeCoopAPI.start_link([decision("start_episode")])

    assert {:ok, {:decided, admission}} =
             AdmissionDispatcher.run_once(admission_dispatcher_options(admission_fake))

    assert admission.result.entry.source_kind == "webhook"
    assert admission.result.episode.destination_transport == "control_plane"
    assert admission.result.episode.destination_conversation_ref == conversation_ref
    assert admission.result.episode.destination_thread_ref == conversation_ref

    {:ok, work_fake} =
      FakeWorkCoopAPI.start_link([
        work_reply("The arbitrary webhook reached the local product pipeline.")
      ])

    assert {:ok, {:executed, execution}} =
             Dispatcher.run_once(work_dispatcher_options(work_fake))

    assert execution.status == :accepted

    assert {:ok, adapters} =
             Adapters.new(%{
               "control_plane" => %{
                 binding: nil,
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    assert {:ok, {:delivered, :message, _delivery_ref}} =
             Ryker.Delivery.Dispatcher.run_once(
               adapters: adapters,
               kind: :message,
               lease_seconds: 60,
               retry_base_seconds: 1,
               retry_max_seconds: 60,
               worker_ref: "webhook-lab-delivery-e2e"
             )

    assert {:ok, conversation} = Projection.lab_conversation(conversation_id)

    assert Enum.any?(conversation.messages, fn message ->
             message.actor == :integration and
               message.text == "Webhook universal · manual.unknown · revision 1" and
               message.status == :decided
           end)

    assert Enum.any?(conversation.messages, fn message ->
             message.actor == :ryker and
               message.text == "The arbitrary webhook reached the local product pipeline."
           end)

    refute inspect(conversation) =~ "private-webhook-payload-marker"

    assert Enum.any?(Projection.lab_index(), &(&1.id == conversation_id))
    refute_receive {:slack_posted, _, _, _, _}
  end

  test "a scoped lifecycle webhook records only an exactly authorized merged publication signal" do
    %{publication: publication} =
      PublicationFixture.published!("webhook-lifecycle-e2e",
        conversation_ref: "slack:T6E06DA3564B2:C456"
      )

    Repo.update_all(
      from(followup in Followup, where: followup.publication_id == ^publication.id),
      set: [merge_sha: String.duplicate("b", 40), pr_state: "merged"]
    )

    payload = %{
      "environment" => "production",
      "kind" => "deployment",
      "references" => [publication.pull_request_url],
      "repository" => "ryker",
      "run_ref" => "deploy:webhook-e2e",
      "state" => "succeeded",
      "target" => "ryker"
    }

    assert post_lifecycle(payload, "deployment-exact").status == 202

    assert %LifecycleEvent{state: "succeeded", wakeup_state: :pending} =
             Repo.get_by!(LifecycleEvent,
               publication_id: publication.id,
               kind: "deployment"
             )

    refute Repo.get_by(LifecycleEvent, publication_id: publication.id, kind: "terraform")

    assert post_lifecycle(
             %{payload | "environment" => "staging", "kind" => "terraform"},
             "deployment-crossed"
           ).status ==
             202

    refute Repo.get_by(LifecycleEvent, publication_id: publication.id, kind: "terraform")
  end

  defp post(body, event_id) do
    conn(:post, "/v1/hooks/universal", body)
    |> put_req_header("authorization", "Bearer #{@secret}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-responder-event-id", event_id)
    |> put_req_header("x-responder-event-type", "new.vendor.event")
    |> Router.call(router_options())
  end

  defp post_to_lab(body, event_id, conversation_ref) do
    conn(:post, "/v1/hooks/universal", body)
    |> put_req_header("authorization", "Bearer #{@secret}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-responder-event-id", event_id)
    |> put_req_header("x-responder-event-type", "manual.unknown")
    |> Router.call(local_router_options(conversation_ref))
  end

  defp post_lifecycle(payload, event_id) do
    assert {:ok, route} =
             Route.new(%{
               auth: {:bearer, @secret},
               destination: %{
                 conversation_ref: "slack:T6E06DA3564B2:C456",
                 thread_ref: nil,
                 transport: "slack"
               },
               name: "deployments",
               publication_lifecycle: %{
                 environments: ["production"],
                 kinds: ["deployment", "terraform"],
                 repositories: ["ryker"],
                 targets: ["ryker"]
               }
             })

    conn(:post, "/v1/hooks/deployments", Jason.encode!(payload))
    |> put_req_header("authorization", "Bearer #{@secret}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-responder-event-id", event_id)
    |> put_req_header("x-responder-event-type", "responder.publication_lifecycle.v1")
    |> Router.call(Router.init(now: fn -> @now end, routes: %{"deployments" => route}))
  end

  defp local_router_options(conversation_ref) do
    assert {:ok, route} =
             Route.new(%{
               auth: {:bearer, @secret},
               destination: %{
                 conversation_ref: conversation_ref,
                 thread_ref: conversation_ref,
                 transport: "control_plane"
               },
               name: "universal",
               work_profile: %{
                 policy: "webhook-conversation-read",
                 policy_digest: String.duplicate("a", 64),
                 repository_ref: "ryker"
               }
             })

    Router.init(now: fn -> @now end, routes: %{"universal" => route})
  end

  defp router_options do
    assert {:ok, route} =
             Route.new(%{
               auth: {:bearer, @secret},
               destination: %{
                 conversation_ref: "slack:T6E06DA3564B2:C456",
                 thread_ref: nil,
                 transport: "slack"
               },
               name: "universal",
               work_profile: %{
                 policy: "webhook-conversation-read",
                 policy_digest: String.duplicate("a", 64),
                 repository_ref: "ryker"
               }
             })

    Router.init(now: fn -> @now end, routes: %{"universal" => route})
  end

  defp admission_dispatcher_options(fake) do
    [
      executor_options: [
        api: FakeCoopAPI,
        client: fake,
        max_polls: 10,
        now: fn -> @now end,
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 300,
      now: fn -> @now end,
      retry_base_ms: 1_000,
      retry_max_ms: 60_000,
      worker_ref: "webhook-e2e:test"
    ]
  end

  defp work_dispatcher_options(fake) do
    [
      executor_options: [
        api: FakeWorkCoopAPI,
        client: fake,
        max_block_ms: 1_000,
        max_polls: 20,
        monotonic_ms: fn -> 0 end,
        now: fn -> @now end,
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 60,
      retry_base_seconds: 1,
      retry_max_seconds: 60,
      worker_ref: "webhook-work-e2e:test"
    ]
  end

  defp decision(action) do
    Jason.encode!(%{
      "action" => action,
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "repository_source" => nil,
      "reason" => "This unknown event needs a new episode so Ryker can inspect it.",
      "work_class" => "standard"
    })
  end

  defp work_reply(message) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => [],
        "state" => "complete"
      }
    })
  end
end
