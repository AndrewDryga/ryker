defmodule Ryker.ControlPlane.StatusConfirmationTest do
  use Ryker.DataCase, async: false
  alias Ryker.Behaviors
  alias Ryker.ControlPlane.{Actions, Paths, Projection, Router}
  alias Ryker.Fixtures.StatusConfirmations
  alias Ryker.Schedules

  # Administrative questions named only the ref: an old Delete erased a
  # newer definition, while old Pause/Resume changed its subsequent work.
  for kind <- [:guidance, :preference, :standing_assignment, :schedule],
      action <- [:active, :inactive, :deleted],
      surface <- [:page, :dialog] do
    test "an old #{surface} #{action} question preserves the edited #{kind}" do
      kind = unquote(kind)
      action = action(kind, unquote(action))
      context = StatusConfirmations.current!(kind, initial_status(kind, action))
      path = path(context, action)
      router = router(Actions.callbacks())
      token = question(router, path, unquote(surface))
      edited = StatusConfirmations.edit!(context)
      response = post(router, path, token)
      stored = StatusConfirmations.fetch!(context)

      assert stored.status == edited.status
      assert stored.revision == edited.revision
      assert stored == edited
      assert response.status == 409
      assert response.resp_body =~ "changed after you opened the page"
    end

    test "a current #{surface} #{action} question changes only the confirmed #{kind} revision" do
      kind = unquote(kind)
      action = action(kind, unquote(action))
      context = StatusConfirmations.current!(kind, initial_status(kind, action))
      path = path(context, action)
      router = router(Actions.callbacks())
      token = question(router, path, unquote(surface))
      response = post(router, path, token)
      stored = StatusConfirmations.fetch!(context)

      assert stored.status == action
      assert stored.revision == context.entity.revision + 1
      assert response.status == 303
    end
  end

  for kind <- [:guidance, :schedule], action <- [:active, :inactive, :deleted] do
    test "a #{kind} edit after POST revalidation preserves it against #{action}" do
      kind = unquote(kind)
      action = action(kind, unquote(action))
      context = StatusConfirmations.current!(kind, initial_status(kind, action))
      path = path(context, action)
      actions = racing_actions(context)
      router = router(actions)
      token = question(router, path, :page)
      response = post(router, path, token)
      stored = StatusConfirmations.fetch!(context)

      assert stored.status == context.entity.status
      assert stored.revision == context.entity.revision + 1
      assert response.status == 409
      assert response.resp_body =~ "changed after you opened the page"
    end
  end

  defp racing_actions(%{kind: :schedule} = context) do
    Map.put(Actions.callbacks(), :set_schedule_status, fn ref, status, revision ->
      StatusConfirmations.edit!(context)
      Schedules.set_status(ref, status, revision)
    end)
  end

  defp racing_actions(context) do
    Map.put(Actions.callbacks(), :set_behavior_status, fn ref, status, revision ->
      StatusConfirmations.edit!(context)
      Behaviors.set_status(ref, status, revision)
    end)
  end

  defp action(:schedule, :inactive), do: :paused
  defp action(_kind, :inactive), do: :disabled
  defp action(_kind, action), do: action

  defp initial_status(:schedule, :active), do: :paused
  defp initial_status(_kind, :active), do: :disabled
  defp initial_status(_kind, _action), do: :active

  defp path(context, action) do
    kind = if context.kind == :schedule, do: "schedule", else: "behavior"
    id = Paths.id(kind, context.entity.ref)
    "/actions/#{kind}/#{id}/#{action}"
  end

  defp router(actions) do
    Router.init(%{
      csrf_secret: String.duplicate("s", 32),
      actions: actions,
      observability: %{},
      projection: Projection.callbacks()
    })
  end

  defp question(router, path, :page) do
    response = Plug.Test.conn(:get, path) |> Map.put(:host, "localhost") |> Router.call(router)
    assert response.status == 200
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, response.resp_body)
    token
  end

  defp question(router, path, :dialog) do
    assert {:ok, question} = Router.question(path, router)
    question.token
  end

  defp post(router, path, token) do
    form = URI.encode_query(%{"_token" => token})

    Plug.Test.conn(:post, path, form)
    |> Map.put(:host, "localhost")
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(router)
  end
end
