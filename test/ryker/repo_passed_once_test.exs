defmodule Ryker.RepoPassedOnceTest do
  @moduledoc """
  A custody check that passed under its own share locks stays passed until the
  transaction ends (`Repo.passed_once?/3`). On 2026-11-03 Work authorization
  repeated the same topic checks once per quoted session, 920 for 176 versions,
  and ran past its transaction limit on every retry. A remembered pass must
  never outlive the transaction whose locks made it true: the next one checks
  again.
  """
  use Ryker.DataCase, async: true
  alias Ryker.Repo

  test "a pass is remembered for the rest of the outermost transaction only" do
    outermost =
      Repo.transaction(fn ->
        assert Repo.passed_once?([:a, :b], & &1, check(:first, true))
        assert Repo.passed_once?([:b, :c], & &1, check(:second, true))

        nested =
          Repo.transaction(fn -> Repo.passed_once?([:a, :c], & &1, check(:nested, true)) end)

        assert nested == {:ok, true}
        :done
      end)

    assert outermost == {:ok, :done}
    assert_received {:checked, :first, [:a, :b]}
    assert_received {:checked, :second, [:c]}
    refute_received {:checked, :nested, _items}

    assert Repo.transaction(fn -> Repo.passed_once?([:a], & &1, check(:next, true)) end) ==
             {:ok, true}

    assert_received {:checked, :next, [:a]}
  end

  test "a rolled-back transaction leaves no pass behind" do
    rolled_back =
      Repo.transaction(fn ->
        assert Repo.passed_once?([:a], & &1, check(:first, true))
        Repo.rollback(:refused)
      end)

    assert rolled_back == {:error, :refused}

    assert Repo.transaction(fn -> Repo.passed_once?([:a], & &1, check(:after, true)) end) ==
             {:ok, true}

    assert_received {:checked, :after, [:a]}
  end

  test "a failed check runs again, and outside a transaction every call checks every item" do
    retried =
      Repo.transaction(fn ->
        refute Repo.passed_once?([:a], & &1, check(:failed, false))
        assert Repo.passed_once?([:a], & &1, check(:retried, true))
        :done
      end)

    assert retried == {:ok, :done}
    assert_received {:checked, :failed, [:a]}
    assert_received {:checked, :retried, [:a]}

    assert Repo.passed_once?([:a], & &1, check(:outside, true))
    assert Repo.passed_once?([:a], & &1, check(:outside_again, true))
    assert_received {:checked, :outside, [:a]}
    assert_received {:checked, :outside_again, [:a]}
  end

  defp check(label, answer) do
    owner = self()

    fn items ->
      send(owner, {:checked, label, items})
      answer
    end
  end
end
