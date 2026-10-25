defmodule Ryker.ControlPlane.RetentionConfirmationTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.ControlPlane.{Actions, CSRF, Paths, Projection, Router}
  alias Ryker.Fixtures.RetainedWork
  alias Ryker.Operator
  alias Ryker.Work

  # A retained copy can receive a newer plan. The old Delete question must
  # not grant permission to throw away that replacement's work.
  for kind <- [:dirty, :unmerged],
      surface <- [:page, :dialog],
      timing <- [:before_post, :after_revalidation] do
    test "an old #{surface} #{kind} question preserves a plan replaced #{timing}" do
      context = RetainedWork.current!(unquote(kind))
      parent = self()

      replace = fn ->
        replacement = RetainedWork.replace!(context)
        send(parent, {:replacement, replacement})
      end

      actions = Actions.callbacks()
      callback_key = callback_key(context.kind)
      callback = Map.fetch!(actions, callback_key)

      actions =
        if unquote(timing) == :after_revalidation do
          Map.put(actions, callback_key, fn ref, fingerprint, viewer ->
            replace.()
            callback.(ref, fingerprint, viewer)
          end)
        else
          actions
        end

      options =
        Router.init(%{
          actions: actions,
          csrf_secret: String.duplicate("s", 32),
          observability: %{},
          projection: Projection.callbacks()
        })

      action = if context.kind == :dirty, do: "discard-changes", else: "discard"
      path = Paths.action("retention", context.session.external_ref, action)
      token = question(options, path, unquote(surface))
      if unquote(timing) == :before_post, do: replace.()
      form = URI.encode_query(%{"_token" => token})

      response =
        Plug.Test.conn(:post, path, form)
        |> Map.put(:host, "localhost")
        |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
        |> Router.call(options)

      assert_receive {:replacement, replacement}
      stored = RetainedWork.fetch!(context)
      assert stored.cleanup_status == :retained
      assert stored == replacement

      refute Repo.exists?(
               from(action in Operator.RetentionAction,
                 where: action.session_id == ^context.session.id
               )
             )

      assert response.status == 409
      assert response.resp_body =~ "changed"
    end
  end

  for kind <- [:dirty, :unmerged], surface <- [:page, :dialog] do
    test "a current #{surface} #{kind} question authorizes only a fresh worker plan" do
      context = RetainedWork.current!(unquote(kind))
      options = live_options()
      assert {:ok, workspace} = options.projection.workspace.(context.session.external_ref)
      assert workspace.discard_plan_fingerprint == context.session.discard_plan_fingerprint
      refute Map.has_key?(workspace, :discard_plan)
      action = if context.kind == :dirty, do: "discard-changes", else: "discard"
      path = Paths.action("retention", context.session.external_ref, action)
      token = question(options, path, unquote(surface))

      # Bookkeeping can change while the person reads, without replacing the observed plan.
      context.session
      |> Work.Session.Changeset.cleanup(%{cleanup_attempt_count: 1})
      |> Repo.update!()

      response = post(options, path, token)
      stored = RetainedWork.fetch!(context)
      assert stored.cleanup_status == :plan_pending
      assert stored.discard_plan_generation == context.session.discard_plan_generation + 1
      assert stored.discard_plan_accept_dirty == (unquote(kind) == :dirty)
      assert stored.discard_plan_accept_unmerged
      assert is_nil(stored.discard_plan)
      assert response.status == 303
    end
  end

  for kind <- [:dirty, :unmerged] do
    test "an unfenced old #{kind} token cannot authorize the current plan" do
      context = RetainedWork.current!(unquote(kind))
      options = live_options()

      {action, intent} =
        if context.kind == :dirty,
          do: {"discard-changes", "retention:discard_changes"},
          else: {"discard", "retention:discard_unmerged"}

      path = Paths.action("retention", context.session.external_ref, action)
      token = CSRF.token(options.csrf_secret, intent, context.session.external_ref)
      response = post(options, path, token)
      assert RetainedWork.fetch!(context) == context.session

      refute Repo.exists?(
               from(action in Operator.RetentionAction,
                 where: action.session_id == ^context.session.id
               )
             )

      assert response.status == 403
    end
  end

  defp live_options do
    Router.init(%{
      actions: Actions.callbacks(),
      csrf_secret: String.duplicate("s", 32),
      observability: %{},
      projection: Projection.callbacks()
    })
  end

  defp post(options, path, token) do
    form = URI.encode_query(%{"_token" => token})

    Plug.Test.conn(:post, path, form)
    |> Map.put(:host, "localhost")
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(options)
  end

  defp callback_key(:dirty), do: :discard_retention_changes
  defp callback_key(:unmerged), do: :discard_retention

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
