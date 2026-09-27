defmodule Ryker.GitHub.EventsTest do
  use Ryker.DataCase, async: true

  alias Ryker.GitHub.{Binding, Events}

  # Repositories shows each repository's GitHub health: when its last delivery
  # arrived and whether Ryker could process it. No trigger watched GitHub
  # deliveries at all until 2026-09-26, so that line caught up only on the
  # page's five-second poll; each delivery is now announced once it commits.
  test "a recorded, repeated and processed delivery reaches the repository pages" do
    binding = github_binding()
    name = binding.name
    :ok = Events.subscribe_deliveries()
    payload = %{"action" => "opened", "number" => 7}

    assert {:ok, event} =
             Events.record(binding, "delivery-1", "pull_request:7", "pull_request", payload)

    assert_received {:github_delivery_updated, ^name}

    assert {:ok, :duplicate} =
             Events.record(binding, "delivery-1", "pull_request:7", "pull_request", payload)

    assert_received {:github_delivery_updated, ^name}

    assert {:ok, _processed} = Events.complete(event, "routed")
    assert_received {:github_delivery_updated, ^name}
  end

  defp github_binding do
    %Binding{
      action_grants: ["read"],
      installation_id: 42,
      max_body_bytes: 40_000,
      name: "repo-#{System.unique_integer([:positive])}",
      repository_full_name: "acme/payments",
      repository_id: System.unique_integer([:positive]),
      ryker_actor_id: 99,
      secret: "webhook-secret",
      work_profile: nil
    }
  end
end
