defmodule Ryker.ConcurrencyCaseTest do
  use ExUnit.Case, async: true
  alias Ryker.ConcurrencyCase

  # The guard against committed rows a test leaves behind runs only in a database its run
  # owns alone. It recognised the isolated name but not a gate partition's, so no gate ran
  # it from 2026-10-02 (2026-10-04 review).
  test "a gate partition's database is the run's own, the shared one is not" do
    assert ConcurrencyCase.exclusive_database?("ryker_test_73401_1171")
    assert ConcurrencyCase.exclusive_database?("ryker_test_73401_1171_p3")
    refute ConcurrencyCase.exclusive_database?("ryker_test")
    refute ConcurrencyCase.exclusive_database?("ryker_test_73401_1171_world")
  end
end
