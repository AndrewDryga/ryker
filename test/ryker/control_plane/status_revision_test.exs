defmodule Ryker.ControlPlane.StatusRevisionTest do
  use Ryker.DataCase, async: false
  alias Ryker.Behaviors
  alias Ryker.ControlPlane.{Actions, CSRF, Paths, Projection, Router}
  alias Ryker.Fixtures.StatusConfirmations
  alias Ryker.Inspectors
  alias Ryker.Learning
  alias Ryker.Memories
  alias Ryker.Schedules

  for kind <- [:guidance, :preference, :standing_assignment, :schedule] do
    test "an invalid #{kind} version cannot change its status" do
      context = StatusConfirmations.current!(unquote(kind), :active)

      for revision <- [nil, 0, -1, "1", 1.0] do
        result = set_status(context, :deleted, revision)
        assert StatusConfirmations.fetch!(context) == context.entity
        assert result == {:error, {invalid_reason(context.kind), :revision}}
      end

      future_revision = context.entity.revision + 1
      result = set_status(context, :deleted, future_revision)
      assert StatusConfirmations.fetch!(context) == context.entity
      assert result == {:error, stale_reason(context.kind)}
    end

    test "an obsolete #{kind} no-op is refused without recording a status decision" do
      context = StatusConfirmations.current!(unquote(kind), :active)
      edited = StatusConfirmations.edit!(context)
      observations = observations(context)
      result = set_status(context, :active, context.entity.revision)

      assert StatusConfirmations.fetch!(context) == edited
      assert observations(context) == observations
      assert result == {:error, stale_reason(context.kind)}
      assert set_status(context, :active, edited.revision) == {:ok, edited}
      assert observations(context) == observations
    end

    test "a #{kind} token without a revision cannot authorize a status change" do
      context = StatusConfirmations.current!(unquote(kind), :active)
      kind = if context.kind == :schedule, do: "schedule", else: "behavior"
      id = Paths.id(kind, context.entity.ref)
      secret = String.duplicate("s", 32)
      old_intent = kind <> ":deleted"
      token = CSRF.token(secret, old_intent, context.entity.ref)
      form = URI.encode_query(%{"_token" => token})
      path = "/actions/#{kind}/#{id}/deleted"

      options =
        Router.init(%{
          csrf_secret: secret,
          actions: Actions.callbacks(),
          observability: %{},
          projection: Projection.callbacks()
        })

      response =
        Plug.Test.conn(:post, path, form)
        |> Map.put(:host, "localhost")
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Router.call(options)

      assert StatusConfirmations.fetch!(context) == context.entity
      assert response.status == 403
    end
  end

  test "a current behavior confirmation survives usage metadata without writing another revision" do
    context = StatusConfirmations.current!(:guidance, :active)
    attributes = %{last_used_at: Repo.now!(), use_count: context.entity.use_count + 1}
    used = context.entity |> Behaviors.Behavior.Changeset.update(attributes) |> Repo.update!()
    result = set_status(context, :active, context.entity.revision)

    assert StatusConfirmations.fetch!(context) == used
    assert result == {:ok, used}
  end

  test "a stale schedule confirmation preserves its running lease and learning receipts" do
    context = StatusConfirmations.current!(:schedule, :active)

    attributes = %{
      lease_ref: Ecto.UUID.generate(),
      lease_owner: "worker:status-confirmation",
      lease_expires_at: DateTime.add(Repo.now!(), 60, :second)
    }

    leased = context.entity |> Schedules.Schedule.Changeset.update(attributes) |> Repo.update!()
    context = %{context | entity: leased}
    edited = StatusConfirmations.edit!(context)
    observations = observations(context)
    result = set_status(context, :paused, leased.revision)

    assert StatusConfirmations.fetch!(context) == edited
    assert observations(context) == observations
    assert result == {:error, :schedule_revision_stale}
    assert set_status(context, :active, edited.revision) == {:ok, edited}
    assert observations(context) == observations
  end

  test "refusing a stale guidance status does not dismiss its pending review" do
    context = StatusConfirmations.current!(:guidance, :active)
    workspace = context.entity.workspace_ref
    assert {:ok, %{created: 1}} = Memories.Reviews.refresh_reviews(workspace, 60)
    [review] = Inspectors.memory_reviews(workspace)
    review_ref = review["review_ref"]
    pending = Repo.fetch!(Memories.MemoryReviewItem.Query.by_ref(review_ref))
    edited = StatusConfirmations.edit!(context)
    result = set_status(context, :deleted, context.entity.revision)

    assert StatusConfirmations.fetch!(context) == edited
    assert Repo.fetch!(Memories.MemoryReviewItem.Query.by_ref(review_ref)) == pending
    assert result == {:error, :behavior_revision_stale}
  end

  defp set_status(%{kind: :schedule, entity: schedule}, status, revision),
    do: Schedules.set_status(schedule.ref, status, revision)

  defp set_status(context, status, revision),
    do: Behaviors.set_status(context.entity.ref, status, revision)

  defp observations(context) do
    Learning.ConversationObservation.Query.all()
    |> Learning.ConversationObservation.Query.by_conversation_ref(context.source.conversation_ref)
    |> Repo.all()
  end

  defp invalid_reason(:schedule), do: :invalid_schedule
  defp invalid_reason(_kind), do: :invalid_behavior
  defp stale_reason(:schedule), do: :schedule_revision_stale
  defp stale_reason(_kind), do: :behavior_revision_stale
end
