defmodule Ryker.Webhooks.RouteTest do
  use ExUnit.Case, async: true

  alias Ryker.Webhooks.Route

  test "accepts bearer and HMAC routes with a host-owned destination" do
    for auth <- [
          {:bearer, "a-secret-token-long-enough"},
          {:hmac_sha256, String.duplicate("h", 32)}
        ] do
      assert {:ok, route} = Route.new(attributes(auth))
      assert route.name == "universal"
      assert route.destination.conversation_ref == "slack:T123:C456"
      assert route.max_body_bytes == 40_000
      assert route.max_clock_skew_seconds == 300
      assert route.work_profile == nil
    end
  end

  test "accepts only a validated host-owned work profile" do
    profile = %{
      policy: "webhook-read-only",
      policy_digest: String.duplicate("a", 64),
      repository_ref: "owner/service"
    }

    assert {:ok, route} =
             attributes({:bearer, "a-secret-token-long-enough"})
             |> Map.put(:work_profile, profile)
             |> Route.new()

    assert route.work_profile.policy == "webhook-read-only"
    assert route.work_profile.repository_ref == "owner/service"

    assert {:error, {:invalid_work_profile, :policy_digest}} =
             attributes({:bearer, "a-secret-token-long-enough"})
             |> Map.put(:work_profile, %{profile | policy_digest: "untrusted"})
             |> Route.new()
  end

  test "publication lifecycle authority is an exact bounded route scope" do
    scope = %{
      environments: ["staging", "production"],
      kinds: ["terraform", "deployment"],
      repositories: ["ryker"],
      targets: ["ryker-api"]
    }

    assert {:ok, route} =
             attributes({:bearer, "a-secret-token-long-enough"})
             |> Map.put(:publication_lifecycle, scope)
             |> Route.new()

    assert route.publication_lifecycle == %{
             environments: ["production", "staging"],
             kinds: ["deployment", "terraform"],
             repositories: ["ryker"],
             targets: ["ryker-api"]
           }

    for invalid <- [
          %{scope | kinds: ["release"]},
          %{scope | repositories: []},
          %{scope | environments: ["production", "production"]},
          Map.put(scope, :extra, ["untrusted"])
        ] do
      assert {:error, {:invalid_webhook_route, :publication_lifecycle}} =
               attributes({:bearer, "a-secret-token-long-enough"})
               |> Map.put(:publication_lifecycle, invalid)
               |> Route.new()
    end
  end

  test "rejects weak credentials, extra fields, and malformed destinations" do
    assert {:error, {:invalid_webhook_route, :auth}} =
             Route.new(attributes({:bearer, "short"}))

    assert {:error, {:invalid_webhook_route, :fields}} =
             Route.new(Map.put(attributes({:bearer, "a-secret-token-long-enough"}), :extra, true))

    assert {:error, {:invalid_webhook_route, :destination}} =
             Route.new(
               put_in(
                 attributes({:bearer, "a-secret-token-long-enough"}),
                 [:destination, :conversation_ref],
                 ""
               )
             )

    assert {:error, {:invalid_webhook_route, :max_body_bytes}} =
             Route.new(
               Map.put(attributes({:bearer, "a-secret-token-long-enough"}), :max_body_bytes, 10)
             )

    assert {:error, {:invalid_webhook_route, :max_body_bytes}} =
             Route.new(
               Map.put(
                 attributes({:bearer, "a-secret-token-long-enough"}),
                 :max_body_bytes,
                 40_001
               )
             )

    assert {:error, {:invalid_webhook_route, :max_clock_skew_seconds}} =
             Route.new(
               Map.put(
                 attributes({:bearer, "a-secret-token-long-enough"}),
                 :max_clock_skew_seconds,
                 3_601
               )
             )

    assert {:error, {:invalid_webhook_route, :fields}} = Route.new("not configuration")
  end

  test "accepts unique keyword configuration" do
    assert {:ok, route} =
             Route.new(
               auth: {:bearer, "a-secret-token-long-enough"},
               destination: %{
                 conversation_ref: "slack:T123:C456",
                 thread_ref: "1787832000.000100",
                 transport: "slack"
               },
               name: "universal"
             )

    assert route.destination.thread_ref == "1787832000.000100"
  end

  defp attributes(auth) do
    %{
      auth: auth,
      destination: %{
        conversation_ref: "slack:T123:C456",
        thread_ref: nil,
        transport: "slack"
      },
      name: "universal"
    }
  end
end
