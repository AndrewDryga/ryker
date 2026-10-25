defmodule Ryker.Slack.ControlValueTest do
  # App Home and the chat interaction handler each kept a reader of a control
  # button's value; one of them raised on a value that was not text. One reader
  # now serves both (2026-10-06 review).
  use ExUnit.Case, async: true
  alias Ryker.Slack.ControlValue

  @resource "behavior:0b0e5d5e-8c9a-4a57-9a4f-1d0f2b0c3a11"

  test "a control's value reads back as the resource and revision it was written with" do
    value = ControlValue.encode("behavior", @resource, 7)

    assert value == "behavior-control:#{@resource}:7"
    assert ControlValue.decode(value, "behavior") == {:ok, @resource, 7}
  end

  test "a value written for another kind, revision or shape is refused" do
    for value <- [
          ControlValue.encode("schedule", "schedule:1", 7),
          "behavior-control:#{@resource}:0",
          "behavior-control:#{@resource}:-1",
          "behavior-control:#{@resource}:7x",
          "behavior-control:#{@resource}",
          "behavior-control:schedule:1:7",
          "behavior-control:7",
          @resource <> ":7",
          nil,
          7
        ] do
      assert ControlValue.decode(value, "behavior") == :error, inspect(value)
    end
  end

  test "a memory control preserves its content fingerprint instead of parsing an integer revision" do
    ref = "memory:one"
    fingerprint = String.duplicate("a", 64)
    value = ControlValue.encode("memory", ref, fingerprint)

    assert ControlValue.decode(value, "memory") == {:ok, ref, fingerprint}

    for invalid <- [
          ref,
          ref <> ":" <> fingerprint,
          "memory-control:#{ref}:7",
          "memory-control:#{ref}:#{String.upcase(fingerprint)}",
          "memory-control:#{ref}:#{String.duplicate("g", 64)}",
          "memory-control:#{ref}:#{String.duplicate("a", 63)}",
          "memory-control:behavior:one:#{fingerprint}",
          value <> ":extra"
        ] do
      assert ControlValue.decode(invalid, "memory") == :error, inspect(invalid)
    end
  end
end
