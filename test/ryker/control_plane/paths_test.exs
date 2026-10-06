defmodule Ryker.ControlPlane.PathsTest do
  @moduledoc """
  Andrew, 2026-10-03, of `/incident-rooms/incident-room%3Ademo-checkout-readiness`: "fuckin ugly,
  make the code more clean and idiomatic". The console built its links in forty places, five
  different ways, each percent-encoding the reference Ryker keeps for a record, prefix and all.
  These hold the one way: a record by its plain id or slug, and `:` readable where a URL allows it.
  """
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.{Paths, WebRouter}

  @id "01f5eb8f-5b61-4303-bead-47da638cd792"

  test "a request is addressed by its id, however the reference it was found by reads" do
    assert Paths.request(@id) == "/timeline/#{@id}"
    # A request a message started has the message's id.
    assert Paths.request("ingress-input:" <> @id) == "/timeline/#{@id}"
    assert Paths.request_id("ingress-input:" <> @id) == @id
    assert Paths.request_id("task-offer:record:task_offer:0512") == nil

    assert Paths.request_attempt(@id, "turn-1") ==
             "/timeline/#{@id}?attempt=turn-1#request-turn-1"

    # A key that names no id is refused rather than percent-encoded into the path.
    assert_raise ArgumentError, fn -> Paths.request("task-offer:record:task_offer:0512") end
  end

  test "a record's page leaves off the prefix its route already names" do
    assert Paths.incident_room("incident-room:demo-checkout-readiness") ==
             "/incident-rooms/demo-checkout-readiness"

    assert Paths.schedule("schedule:" <> @id) == "/schedules/#{@id}"
    assert Paths.channel("T0BHXKZJVDX", "C0BLU1GACKC") == "/channels/T0BHXKZJVDX/C0BLU1GACKC"
    assert Paths.failure("delivery", "delivery:" <> @id) == "/failures/delivery/#{@id}"
    assert Paths.failure("work", "ingress-input:" <> @id) == "/failures/work/#{@id}"
    assert Paths.failure("learning", @id) == "/failures/learning/#{@id}"

    # A delivery failure can be a platform action's, whose reference keeps its own prefix.
    assert Paths.failure("delivery", "platform-action:a91b") ==
             "/failures/delivery/platform-action:a91b"

    assert Paths.reference("delivery", "platform-action:a91b") == {:ok, "platform-action:a91b"}
    assert Paths.reference("delivery", @id) == {:ok, "delivery:" <> @id}

    # The old address, prefix and all, is no address now: a clean cut, not an alias.
    assert Paths.reference("delivery", "delivery:" <> @id) == :error
    assert Paths.reference("slack_incident", "incident-room:demo") == :error
  end

  test "an action names its record the same way, and keeps a colon a reference needs readable" do
    assert Paths.action("memory", "memory:" <> @id, "forget") == "/actions/memory/#{@id}/forget"
    assert Paths.action("work", "ingress-input:" <> @id, "retry") == "/actions/work/#{@id}/retry"

    assert Paths.action("person", "slack:T123:U456", "forget") ==
             "/actions/person/slack:T123:U456/forget"

    # What the address leaves off comes back for the record's own store.
    assert Paths.reference("memory", @id) == {:ok, "memory:" <> @id}
    assert Paths.reference("slack_incident", "demo") == {:ok, "incident-room:demo"}
    assert Paths.reference("person", "slack:T1:U1") == {:ok, "slack:T1:U1"}
    assert Paths.reference("work", @id) == :request
  end

  test "query values keep colons readable and leave out what is empty" do
    assert Paths.query("/activity", conversation: "slack:T0BHXKZJVDX:C0BLU1GACKC", mode: "all") ==
             "/activity?conversation=slack:T0BHXKZJVDX:C0BLU1GACKC&mode=all"

    assert Paths.query("/memory/learned", %{"related_to" => "knowledge:" <> @id}) ==
             "/memory/learned?related_to=knowledge:#{@id}"

    assert Paths.query("/activity", page: nil, filter: "") == "/activity"
    assert Paths.query("/feedback", q: "a b&c=d+e") == "/feedback?q=a+b%26c%3Dd%2Be"

    # A usage drilldown asks for the calls that named no effort with an empty value.
    assert Paths.encode_query([{"usage_effort", ""}, {"usage_model", "opus"}]) ==
             "usage_effort=&usage_model=opus"
  end

  # The forward that serves everything but pages warns on a verified path, so a `~p` link that
  # names no page fails the build instead of answering 404.
  test "a verified path names a page, never what the forward serves" do
    assert {nil, false} = WebRouter.__verify_route__(["timeline", @id])
    assert {nil, false} = WebRouter.__verify_route__(["incident-rooms", "demo"])

    assert {nil, false} =
             WebRouter.__verify_route__(["failures", "delivery", "platform-action:a"])

    assert {_forward, true} = WebRouter.__verify_route__(["actions", "memory", @id, "forget"])
  end
end
