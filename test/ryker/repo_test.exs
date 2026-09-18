defmodule Ryker.RepoTest do
  use ExUnit.Case, async: true

  alias Ryker.Repo

  test "a lost concurrent transaction is a conflict and an exhausted budget, a timeout only the latter" do
    for code <- [:serialization_failure, :deadlock_detected] do
      assert Repo.conflict?(postgres_error(code))
      assert Repo.budget_exhausted?(postgres_error(code))
    end

    for code <- [:query_canceled, :lock_not_available] do
      refute Repo.conflict?(postgres_error(code))
      assert Repo.budget_exhausted?(postgres_error(code))
    end

    refute Repo.conflict?(postgres_error(:unique_violation))
    refute Repo.budget_exhausted?(postgres_error(:unique_violation))
    refute Repo.conflict?(%RuntimeError{message: "not a database error"})
  end

  defp postgres_error(code), do: %Postgrex.Error{postgres: %{code: code}}
end
