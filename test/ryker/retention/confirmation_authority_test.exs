defmodule Ryker.Retention.ConfirmationAuthorityTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.Fixtures.RetainedWork
  alias Ryker.Operator
  alias Ryker.Work

  # The public four-argument API also accepted nil, bypassing the plan fence
  # even when a caller chose that supposedly fenced interface.
  for kind <- [:dirty, :unmerged] do
    test "a nil #{kind} fingerprint grants no cleanup authority" do
      context = RetainedWork.current!(unquote(kind))
      result = discard(context, nil)
      stored = RetainedWork.fetch!(context)
      assert stored.cleanup_status == :retained
      assert stored == context.session
      assert result == {:error, {:invalid_retention_operator, :expected_plan_fingerprint}}
      assert action_count(context) == 0
    end

    test "malformed #{kind} fingerprints preserve all cleanup custody" do
      context = RetainedWork.current!(unquote(kind))

      for fingerprint <- ["", String.duplicate("a", 63), String.duplicate("A", 64), 1, [], %{}] do
        result = discard(context, fingerprint)
        assert RetainedWork.fetch!(context) == context.session
        assert action_count(context) == 0
        assert result == {:error, {:invalid_retention_operator, :expected_plan_fingerprint}}
      end
    end

    test "an unobserved #{kind} fingerprint grants no cleanup authority" do
      context = RetainedWork.current!(unquote(kind))
      result = discard(context, String.duplicate("b", 64))
      assert RetainedWork.fetch!(context) == context.session
      assert action_count(context) == 0
      assert result == {:error, :retention_discard_plan_stale}
    end

    test "an exact #{kind} retry records one decision and a changed request conflicts" do
      context = RetainedWork.current!(unquote(kind))
      fingerprint = context.session.discard_plan_fingerprint

      assert {:ok, %{outcome: :discard_requested, session: requested}} =
               discard(context, fingerprint)

      assert requested.cleanup_status == :plan_pending
      assert requested.discard_plan_generation == context.session.discard_plan_generation + 1
      assert requested.discard_plan_accept_unmerged
      assert requested.discard_plan_accept_dirty == (unquote(kind) == :dirty)

      assert {:ok, %{outcome: :duplicate, session: ^requested}} = discard(context, fingerprint)
      assert action_count(context) == 1

      for {expected, actor} <- [
            {String.duplicate("b", 64), "control-plane:local"},
            {fingerprint, "control-plane:other"}
          ] do
        result = discard(context, expected, actor)
        assert RetainedWork.fetch!(context) == requested
        assert action_count(context) == 1
        assert result == {:error, :retention_operator_action_conflict}
      end
    end
  end

  defp action_count(%{session: %Work.Session{} = session}) do
    Repo.aggregate(
      from(action in Operator.RetentionAction, where: action.session_id == ^session.id),
      :count
    )
  end

  defp action_count(_context), do: raise(ArgumentError, "unsupported retained state")

  defp discard(context, fingerprint, actor \\ "control-plane:local")

  defp discard(%{kind: :dirty, session: %Work.Session{} = session}, fingerprint, actor) do
    Operator.Retention.discard_changes(
      session.external_ref,
      fingerprint,
      actor,
      "retention:confirmation:nil"
    )
  end

  defp discard(%{kind: :unmerged, session: %Work.Session{} = session}, fingerprint, actor) do
    Operator.Retention.discard_unmerged(
      session.external_ref,
      fingerprint,
      actor,
      "retention:confirmation:nil"
    )
  end

  defp discard(_context, _fingerprint, _actor),
    do: raise(ArgumentError, "unsupported retained state")
end
