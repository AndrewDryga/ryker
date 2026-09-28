defmodule Ryker.GitHub.DeliveryPollerTest do
  @moduledoc """
  On 2026-09-28 three comments on Ryker's own pull request never arrived:
  the installation listens on 127.0.0.1, which GitHub cannot reach, and no
  GitHub event had ever been recorded there. GitHub keeps the deliveries it
  could not make; Ryker fetches them and routes each exactly as if GitHub had
  reached it, once.
  """
  use Ryker.DataCase, async: false

  alias Ryker.GitHub.{Binding, DeliveryPoller, Event}
  alias Ryker.Ingress.Inbox.Entry

  @secret String.duplicate("s", 32)
  @now ~U[2026-09-28 21:00:00Z]

  defmodule GitHub do
    @moduledoc false
    # GitHub's delivery API as a test double: the list, then each delivery.
    def request(
          %{deliveries: deliveries, payloads: payloads, test: test},
          :get,
          path,
          nil,
          _headers
        ) do
      send(test, {:github, path})

      case path do
        "/app/hook/deliveries?per_page=100" ->
          {:ok, %{status: 200, body: deliveries, headers: []}}

        "/app/hook/deliveries/" <> id ->
          payload = Map.fetch!(payloads, String.to_integer(id))
          {:ok, %{status: 200, body: %{"request" => %{"payload" => payload}}, headers: []}}
      end
    end
  end

  test "a comment GitHub could not deliver is fetched and routed once, as GitHub would have" do
    comment = delivery(1, "delivery-comment", "issue_comment", ~U[2026-09-28 20:50:00Z])
    state = state([comment], %{1 => comment_payload()})

    state = DeliveryPoller.poll(state)

    # Nothing is left in the poller's mailbox: the in-process request's copy
    # of its response crashed the live poller on its first delivery.
    refute_received {_ref, {_status, _headers, _body}}

    # Routed through the router: recorded as a GitHub delivery and admitted
    # as a request on the pull request's thread.
    assert [%Event{event_name: "issue_comment", disposition: "routed"}] = Repo.all(Event)
    assert [entry] = Repo.all(Entry)
    assert entry.source_kind == "github"
    assert entry.destination_thread_ref == "github:github-main:pull:42"
    assert_received {:github, "/app/hook/deliveries/1"}

    # Asked again, it is neither fetched nor routed a second time, even by a
    # poller that forgot what it saw (a restart).
    DeliveryPoller.poll(state)
    DeliveryPoller.poll(%{state | seen: MapSet.new()})
    refute_received {:github, "/app/hook/deliveries/1"}
    assert Repo.aggregate(Event, :count) == 1
    assert Repo.aggregate(Entry, :count) == 1
  end

  test "a delivery older than a day and a ping are not replayed" do
    old = delivery(1, "delivery-old", "issue_comment", ~U[2026-09-26 20:00:00Z])
    ping = delivery(2, "delivery-ping", "ping", ~U[2026-09-28 20:55:00Z])

    DeliveryPoller.poll(state([old, ping], %{1 => comment_payload(), 2 => %{}}))

    refute_received {:github, "/app/hook/deliveries/" <> _id}
    assert Repo.aggregate(Event, :count) == 0
  end

  defp state(deliveries, payloads) do
    DeliveryPoller.state(%{
      app_http: %{deliveries: deliveries, payloads: payloads, test: self()},
      requester: GitHub,
      clock: fn -> @now end,
      router: [
        bindings: %{"github-main" => binding!()},
        bot_login: "ryker-test",
        repository_access: fn _binding, _payload -> :ok end,
        secret: @secret
      ]
    })
  end

  defp delivery(id, guid, event, at),
    do: %{
      "id" => id,
      "guid" => guid,
      "event" => event,
      "action" => "created",
      "delivered_at" => DateTime.to_iso8601(at),
      "status" => "failed to connect to host",
      "status_code" => 0
    }

  defp binding! do
    {:ok, binding} =
      Binding.new(%{
        installation_id: 41,
        name: "github-main",
        repository_full_name: "octo/example",
        repository_id: 99,
        ryker_actor_id: 99,
        secret: @secret,
        work_profile: %{
          policy: "github-read-only",
          policy_digest: String.duplicate("a", 64),
          repository_ref: "octo/example"
        }
      })

    binding
  end

  # The pull request comment a person left for Ryker, as GitHub records it.
  defp comment_payload,
    do: %{
      "action" => "created",
      "comment" => %{
        "body" => "@ryker-test Can you bring this up to date?",
        "created_at" => "2026-09-28T20:50:00Z",
        "id" => 9001,
        "updated_at" => "2026-09-28T20:50:00Z"
      },
      "installation" => %{"id" => 41},
      "issue" => %{"number" => 42, "pull_request" => %{}},
      "repository" => %{"full_name" => "octo/example", "id" => 99},
      "sender" => %{"id" => 7, "login" => "octocat", "type" => "User"}
    }
end
