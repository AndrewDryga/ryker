defmodule Ryker.Emisar.FieldsTest do
  # The approval status and its review each checked these with a copy of
  # their own until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.Emisar.Fields

  test "a time must carry a zero offset" do
    assert Fields.timestamp("2026-10-08T12:00:00Z") == :ok
    assert Fields.timestamp("2026-10-08T12:00:00+02:00") == {:error, :timestamp}
    assert Fields.timestamp("yesterday") == {:error, :timestamp}
    assert Fields.timestamp(nil) == {:error, :timestamp}
  end

  test "a reference is nonblank and bounded, and an optional text may be absent" do
    assert Fields.reference("run-1", 16) == :ok
    assert Fields.reference(String.duplicate("r", 17), 16) == {:error, :reference}
    assert Fields.reference(" ", 16) == {:error, :reference}
    assert Fields.optional_text(nil, 16) == :ok
    assert Fields.optional_text("", 16) == {:error, :reference}
  end
end
