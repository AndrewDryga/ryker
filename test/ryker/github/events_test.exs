defmodule Ryker.GitHub.EventsTest do
  use Ryker.DataCase, async: true
  alias Ryker.GitHub.{Binding, Event, Events}

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

    assert Events.record(binding, "delivery-1", "pull_request:7", "pull_request", payload) ==
             {:ok, :duplicate}

    assert_received {:github_delivery_updated, ^name}

    assert {:ok, _processed} = Events.complete(event, "routed")
    assert_received {:github_delivery_updated, ^name}
  end

  # Only a delivery whose processing failed is processed again; one that was
  # taken stays a duplicate, and so does the second of two copies racing.
  test "a failed delivery is processed again once, and a processed one never" do
    binding = github_binding()
    payload = %{"action" => "created", "comment" => %{"id" => 7}}
    record = fn -> Events.record(binding, "delivery-2", "comment:7", "issue_comment", payload) end

    assert {:ok, event} = record.()
    assert {:ok, _failed} = Events.complete(event, "failed", "temporarily_unavailable")

    assert {:ok, %Event{id: id, disposition: "received", reason: nil, processed_at: nil}} =
             record.()

    assert id == event.id
    assert record.() == {:ok, :duplicate}

    assert {:ok, _routed} = Events.complete(%{event | id: id}, "routed")
    assert record.() == {:ok, :duplicate}
    assert Repo.get!(Event, id).duplicate_count == 2
  end

  # A request that crashed after recording its delivery left it "received" for
  # good: never processed, shown as pending, and kept by retention as custody.
  test "a delivery a crash left unprocessed is taken again after ten minutes" do
    binding = github_binding()
    payload = %{"action" => "created", "comment" => %{"id" => 8}}
    record = fn -> Events.record(binding, "delivery-3", "comment:8", "issue_comment", payload) end

    assert {:ok, %Event{id: id}} = record.()
    assert record.() == {:ok, :duplicate}
    assert Events.settled(["delivery-3", "delivery-unknown"]) == MapSet.new(["delivery-3"])

    nine_minutes_ago = DateTime.add(Repo.now!(), -9 * 60, :second)
    Repo.update_all(Event, set: [inserted_at: nine_minutes_ago])
    assert record.() == {:ok, :duplicate}

    eleven_minutes_ago = DateTime.add(Repo.now!(), -11 * 60, :second)
    Repo.update_all(Event, set: [inserted_at: eleven_minutes_ago])
    assert Events.settled(["delivery-3"]) == MapSet.new()
    assert {:ok, %Event{id: ^id, disposition: "received"}} = record.()
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
      work_profile: nil
    }
  end
end
