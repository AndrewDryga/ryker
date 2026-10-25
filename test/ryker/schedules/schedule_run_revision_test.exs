defmodule Ryker.Schedules.ScheduleRunRevisionTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.StatusConfirmations
  alias Ryker.Operator
  alias Ryker.Schedules

  for surface <- [:console, :slack] do
    test "invalid and unobserved #{surface} revisions cannot start work or record an action" do
      context = StatusConfirmations.current!(:schedule, :active)
      parent = self()

      resolver = fn _schedule ->
        send(parent, :resolved_policy)
        {:ok, %{digest: String.duplicate("c", 64), name: "scheduled-read"}}
      end

      for revision <- [nil, 0, -1, "1", 1.0, context.entity.revision + 1] do
        result = run_now(unquote(surface), context, revision, "interaction:invalid-run", resolver)
        assert Repo.all(Schedules.ScheduleOccurrence.Query.running(context.entity.id)) == []
        assert Repo.aggregate(Operator.Action, :count) == 0
        assert StatusConfirmations.fetch!(context) == context.entity

        if is_integer(revision) and revision > 0 do
          assert result == {:error, :schedule_revision_stale}
        else
          assert result == {:error, {:invalid_schedule, :revision}}
        end
      end

      refute_received :resolved_policy
    end

    test "a #{surface} action retry keeps its original occurrence and rejects a different revision" do
      context = StatusConfirmations.current!(:schedule, :active)
      action_ref = "interaction:run-retry"
      assert {:ok, first} = run_now(unquote(surface), context, 1, action_ref, &policy/1)
      stored = StatusConfirmations.fetch!(context)
      assert {:ok, duplicate} = run_now(unquote(surface), context, 1, action_ref, &policy/1)

      assert duplicate.status == :duplicate
      assert duplicate.outcome == first.outcome
      assert Repo.aggregate(Operator.Action, :count) == 1

      assert [%{trigger: :manual}] =
               Repo.all(Schedules.ScheduleOccurrence.Query.running(context.entity.id))

      conflict = run_now(unquote(surface), context, stored.revision, action_ref, &policy/1)
      assert StatusConfirmations.fetch!(context) == stored
      assert Repo.aggregate(Operator.Action, :count) == 1
      assert conflict == {:error, :operator_action_conflict}
    end

    for status <- [:active, :paused, :completed, :expired, :deleted] do
      test "a stale #{surface} run cannot change an edited #{status} definition" do
        context = StatusConfirmations.current!(:schedule, :active)

        attributes = %{
          expires_at: DateTime.add(Repo.now!(), -1, :second),
          revision: context.entity.revision + 1,
          status: unquote(status)
        }

        edited =
          context.entity |> Schedules.Schedule.Changeset.update(attributes) |> Repo.update!()

        result = run_now(unquote(surface), context, 1, "interaction:stale-run", &policy/1)
        assert Repo.all(Schedules.ScheduleOccurrence.Query.running(context.entity.id)) == []
        assert StatusConfirmations.fetch!(context) == edited
        assert Repo.aggregate(Operator.Action, :count) == 0
        assert result == {:error, :schedule_revision_stale}
      end
    end
  end

  test "a foreign workspace cannot learn whether a schedule revision changed" do
    context = StatusConfirmations.current!(:schedule, :active)
    edited = StatusConfirmations.edit!(context)
    scope = %{conversation_prefix: "slack:TOTHER:", transport: "slack"}

    result =
      Schedules.run_now(
        context.entity.ref,
        context.entity.revision,
        "slack:user:U123",
        "interaction:foreign-run",
        scope,
        &policy/1
      )

    assert StatusConfirmations.fetch!(context) == edited
    assert Repo.all(Schedules.ScheduleOccurrence.Query.running(context.entity.id)) == []
    assert Repo.aggregate(Operator.Action, :count) == 0
    assert result == {:error, :schedule_scope_mismatch}
  end

  defp run_now(:console, context, revision, action_ref, resolver) do
    Schedules.run_now_for_operator(
      context.entity.ref,
      revision,
      "control-plane:local",
      action_ref,
      resolver
    )
  end

  defp run_now(:slack, context, revision, action_ref, resolver) do
    ["slack", workspace, _channel] = String.split(context.source.conversation_ref, ":")
    scope = %{conversation_prefix: "slack:#{workspace}:", transport: "slack"}

    Schedules.run_now(
      context.entity.ref,
      revision,
      "slack:user:U123",
      action_ref,
      scope,
      resolver
    )
  end

  defp policy(_schedule),
    do: {:ok, %{digest: String.duplicate("c", 64), name: "scheduled-read"}}
end
