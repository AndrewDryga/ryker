defmodule Ryker.AdapterTest do
  # Forty-five places asked this with a copy of their own until 2026-10-08,
  # under six names (callback?, requester?, transcriber?, module_exports?,
  # implements?, context_api?).
  use ExUnit.Case, async: true
  alias Ryker.Adapter

  test "a module stands in only when it loads and exports every function asked for" do
    assert Adapter.implements?(String, length: 1, upcase: 1)
    refute Adapter.implements?(String, length: 1, no_such_function: 1)
    refute Adapter.implements?(String, length: 2)
    refute Adapter.implements?(Ryker.NoSuchModule, length: 1)
    refute Adapter.implements?(nil, length: 1)
    refute Adapter.implements?("String", length: 1)
  end
end
