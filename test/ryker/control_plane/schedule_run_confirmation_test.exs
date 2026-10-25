defmodule Ryker.ControlPlane.ScheduleRunConfirmationTest do
  use Ryker.DataCase, async: false
  alias Ryker.ControlPlane.{Actions, Paths, Projection, Router}
  alias Ryker.Fixtures.StatusConfirmations
  alias Ryker.Operator
  alias Ryker.Schedules

  # Run now signed the displayed revision but dropped it before dispatch: an
  # edit after POST validation started work the operator had never confirmed.
  for surface <- [:page, :dialog] do
    test "an edit after a #{surface} Run now confirmation cannot start its replacement" do
      context = StatusConfirmations.current!(:schedule, :active)
      parent = self()

      resolver = fn schedule ->
        send(parent, {:resolved_policy, schedule.revision})
        {:ok, %{digest: String.duplicate("c", 64), name: "scheduled-read"}}
      end

      actions = Actions.callbacks(nil, %{}, %{}, resolver)
      callback = actions.run_schedule

      actions =
        Map.put(actions, :run_schedule, fn ref, revision, viewer ->
          StatusConfirmations.edit!(context)
          callback.(ref, revision, viewer)
        end)

      options =
        Router.init(%{
          actions: actions,
          csrf_secret: String.duplicate("s", 32),
          observability: %{},
          projection: Projection.callbacks()
        })

      id = Paths.id("schedule", context.entity.ref)
      path = "/actions/schedule/#{id}/run-now"
      token = question(options, path, unquote(surface))
      form = URI.encode_query(%{"_token" => token})

      response =
        Plug.Test.conn(:post, path, form)
        |> Map.put(:host, "localhost")
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Router.call(options)

      assert Repo.all(Schedules.ScheduleOccurrence.Query.running(context.entity.id)) == []
      assert Repo.aggregate(Operator.Action, :count) == 0
      assert StatusConfirmations.fetch!(context).revision == context.entity.revision + 1
      refute_received {:resolved_policy, _revision}
      assert response.status == 409
      assert response.resp_body =~ "changed"
    end
  end

  for surface <- [:page, :dialog] do
    test "a current #{surface} Run now question starts its displayed schedule once" do
      context = StatusConfirmations.current!(:schedule, :active)
      parent = self()

      resolver = fn schedule ->
        send(parent, {:resolved_policy, schedule.revision})
        {:ok, %{digest: String.duplicate("c", 64), name: "scheduled-read"}}
      end

      options =
        Router.init(%{
          actions: Actions.callbacks(nil, %{}, %{}, resolver),
          csrf_secret: String.duplicate("s", 32),
          observability: %{},
          projection: Projection.callbacks()
        })

      id = Paths.id("schedule", context.entity.ref)
      path = "/actions/schedule/#{id}/run-now"
      token = question(options, path, unquote(surface))
      form = URI.encode_query(%{"_token" => token})

      response =
        Plug.Test.conn(:post, path, form)
        |> Map.put(:host, "localhost")
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Router.call(options)

      assert [%{trigger: :manual}] =
               Repo.all(Schedules.ScheduleOccurrence.Query.running(context.entity.id))

      assert StatusConfirmations.fetch!(context).next_occurrence_at ==
               context.entity.next_occurrence_at

      revision = context.entity.revision
      assert_received {:resolved_policy, ^revision}
      refute_received {:resolved_policy, _revision}
      assert response.status == 303
    end
  end

  defp question(options, path, :page) do
    response = Plug.Test.conn(:get, path) |> Map.put(:host, "localhost") |> Router.call(options)
    assert response.status == 200
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, response.resp_body)
    token
  end

  defp question(options, path, :dialog) do
    assert {:ok, question} = Router.question(path, options)
    question.token
  end
end
