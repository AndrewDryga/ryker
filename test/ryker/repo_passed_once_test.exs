defmodule Ryker.RepoPassedOnceTest do
  @moduledoc """
  A custody check that passed under its own share locks stays passed until the
  transaction ends (`Repo.passed_once?/2`). On 2026-11-03 Work authorization
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
        assert Repo.passed_once?(:topic, check(:first, true))
        assert Repo.passed_once?(:topic, check(:again, true))

        nested = Repo.transaction(fn -> Repo.passed_once?(:topic, check(:nested, true)) end)
        assert nested == {:ok, true}
        :done
      end)

    assert outermost == {:ok, :done}
    assert_received {:checked, :first}
    refute_received {:checked, :again}
    refute_received {:checked, :nested}

    assert Repo.transaction(fn -> Repo.passed_once?(:topic, check(:next, true)) end) ==
             {:ok, true}

    assert_received {:checked, :next}
  end

  test "a rolled-back transaction leaves no pass behind" do
    rolled_back =
      Repo.transaction(fn ->
        assert Repo.passed_once?(:topic, check(:first, true))
        Repo.rollback(:refused)
      end)

    assert rolled_back == {:error, :refused}

    assert Repo.transaction(fn -> Repo.passed_once?(:topic, check(:after, true)) end) ==
             {:ok, true}

    assert_received {:checked, :after}
  end

  test "a failed check runs again, and outside a transaction every call runs" do
    retried =
      Repo.transaction(fn ->
        refute Repo.passed_once?(:topic, check(:failed, false))
        assert Repo.passed_once?(:topic, check(:retried, true))
        :done
      end)

    assert retried == {:ok, :done}
    assert_received {:checked, :failed}
    assert_received {:checked, :retried}

    assert Repo.passed_once?(:topic, check(:outside, true))
    assert Repo.passed_once?(:topic, check(:outside_again, true))
    assert_received {:checked, :outside}
    assert_received {:checked, :outside_again}
  end

  defp check(label, answer) do
    owner = self()

    fn ->
      send(owner, {:checked, label})
      answer
    end
  end
end
