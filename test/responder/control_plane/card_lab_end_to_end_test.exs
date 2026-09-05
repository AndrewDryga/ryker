defmodule Responder.ControlPlane.CardLabEndToEndTest do
  use Responder.DataCase, async: false
  import Plug.Conn
  alias Responder.ControlPlane.{CardLabDelivery, CardLabWorker, CSRF, Projection, Router}
  alias Responder.Slack.{ChannelMembership, Client}

  @secret String.duplicate("s", 32)

  defmodule Requester do
    def request(agent, method, path, document, _headers) do
      %{owner: owner, fail_update: fail_update} = Agent.get(agent, & &1)
      send(owner, {:slack_request, method, path, document})

      body =
        case URI.parse(path).path do
          "/conversations.info" ->
            %{
              "channel" => %{
                "id" => "C123",
                "name" => "test",
                "is_member" => true,
                "is_archived" => false,
                "is_ext_shared" => false
              }
            }

          "/conversations.history" ->
            %{"messages" => [], "has_more" => false}

          "/chat.postMessage" ->
            %{"ts" => "1788562304.000100"}

          "/chat.update" ->
            if fail_update,
              do: %{"ok" => false, "error" => "ratelimited"},
              else: %{"ts" => document["ts"], "channel" => document["channel"]}
        end

      {:ok, %{body: Map.put_new(body, "ok", true), headers: [], status: 200}}
    end
  end

  setup do
    previous = Application.get_env(:responder, :slack)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:responder, :slack, previous),
        else: Application.delete_env(:responder, :slack)
    end)

    owner = self()
    {:ok, http} = Agent.start_link(fn -> %{owner: owner, fail_update: false} end)
    {:ok, client} = Client.new(http: http, requester: Requester)

    Application.put_env(:responder, :slack,
      identity: %{workspace_ref: "T123"},
      bot_client: client
    )

    Repo.insert!(%ChannelMembership{
      id: Ecto.UUID.generate(),
      workspace_ref: "T123",
      channel_ref: "C123",
      status: :joined,
      generation: 1,
      private: false,
      external_shared: false,
      joined_at: DateTime.utc_now()
    })

    options =
      Router.init(%{
        csrf_secret: @secret,
        observability: %{},
        projection: Projection.callbacks(),
        actions: %{
          describe_card_slack_target: &CardLabDelivery.describe_target/2,
          post_card_to_slack: &CardLabDelivery.enqueue/5,
          transition_card_slack_post: &CardLabDelivery.transition/3,
          retry_card_slack_post: &CardLabDelivery.retry/2
        }
      })

    %{options: options, http: http}
  end

  test "confirmed HTTP actions traverse durable custody and update one native Slack specimen", %{
    options: options,
    http: http
  } do
    path = "/card-lab/incident-room/provisioning"
    page = request(:get, path, %{}, options)
    assert page.status == 200
    assert page.resp_body =~ "Review Slack post"
    assert CardLabDelivery.snapshot("incident-room").posts == []
    refute_received {:slack_request, :post, _, _}

    review =
      request(
        :post,
        path <> "/slack/preview",
        %{
          "_token" => CSRF.token(@secret, "card_lab:prepare_slack", "incident-room:provisioning"),
          "workspace_ref" => "T123",
          "channel_ref" => "C123"
        },
        options
      )

    assert review.status == 200
    assert review.resp_body =~ "#test"
    post_form = fields(review)
    assert request(:post, path <> "/slack/post", post_form, options).status == 303

    worker = start_supervised!({CardLabWorker, []})
    assert_receive {:slack_request, :post, "/chat.postMessage", payload}, 1_000
    :sys.get_state(worker)
    stop_supervised(CardLabWorker)
    assert payload["metadata"]["event_payload"]["id"] == "card-lab:" <> post_form["request_id"]
    assert payload["text"] =~ "Card Lab"
    [post] = CardLabDelivery.snapshot("incident-room").posts
    assert post.status == :posted
    assert {:ok, ^post} = CardLabDelivery.fetch(post.id)

    rendered = request(:get, path, %{}, options).resp_body
    assert rendered =~ "Open message in Slack"
    assert rendered =~ "p1788562304000100"

    update_path = "/card-lab/incident-room/resolved/slack/#{post.id}/update"
    confirmation = request(:get, update_path, %{}, options)
    assert confirmation.status == 200
    assert confirmation.resp_body =~ "Resolved"
    update_form = fields(confirmation)

    assert request(:post, update_path, Map.put(update_form, "revision", "999"), options).status ==
             403

    assert request(:post, update_path, update_form, options).status == 303
    assert request(:post, update_path, update_form, options).status == 403

    Agent.update(http, &%{&1 | fail_update: true})
    {:ok, %{client: configured_client}} = CardLabDelivery.settings()
    {:ok, frozen} = CardLabDelivery.fetch(post.id)

    assert {:error, {:delivery_rate_limited, _, _}} =
             Client.update_card_specimen(
               configured_client,
               "C123",
               post.message_ref,
               frozen.payload,
               "card-lab:" <> post.id
             )

    assert {:ok, pending} = CardLabDelivery.run_once()
    assert pending.status == :pending
    assert pending.last_error =~ "Slack rate limited this specimen"
    retry_path = "/card-lab/incident-room/provisioning/slack/#{post.id}/retry"
    retry = request(:get, retry_path, %{}, options)
    assert retry.resp_body =~ "Resolved"
    assert request(:post, retry_path, fields(retry), options).status == 303

    Agent.update(http, &%{&1 | fail_update: false})
    assert {:ok, completed} = CardLabDelivery.run_once()
    assert completed.status == :posted
    assert completed.message_ref == post.message_ref
    assert completed.delivered_state_id == "resolved"
    refute_received {:slack_request, :post, "/chat.postMessage", _}
    assert {:error, :card_lab_post_not_found} = CardLabDelivery.fetch(Ecto.UUID.generate())
    assert {:error, :card_lab_post_not_found} = CardLabDelivery.fetch("not-an-id")
    assert request(:get, path <> "/slack/missing/update", %{}, options).status == 404
    assert request(:post, update_path, %{}, options).status == 400
    assert request(:post, path <> "/slack/preview", %{}, options).status == 400
    assert request(:post, path <> "/slack/post", %{}, options).status == 400

    {:ok, latest} = CardLabDelivery.fetch(post.id)

    assert {:error, :card_lab_specimen_not_found} =
             CardLabDelivery.transition(latest.id, "missing", latest.revision)
  end

  defp fields(conn),
    do:
      conn.resp_body
      |> then(&Regex.scan(~r/<input type="hidden" name="([^"]+)" value="([^"]*)"/, &1))
      |> Map.new(fn [_, key, value] -> {key, value} end)

  defp request(method, path, fields, options) do
    Plug.Test.conn(method, path, URI.encode_query(fields))
    |> Map.put(:host, "localhost")
    |> put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(options)
  end
end
