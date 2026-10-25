defmodule Ryker.ControlPlane.MemoryForgettingConfirmationTest do
  use Ryker.DataCase, async: false
  alias Ryker.ControlPlane.{Actions, MemoryProjection, Paths, Projection, Router}
  alias Ryker.Fixtures.MemoryConfirmations
  alias Ryker.Memories

  setup do
    context = MemoryConfirmations.current!()
    path = "/actions/memory/#{Paths.id("memory", context.memory.ref)}/forget"
    %{context: context, path: path}
  end

  # Review edits keep the same ref. An old question approved erasing the new
  # subject/value as well, losing words the person never confirmed forgetting.
  for surface <- [:page, :dialog], field <- ["subject", "value"] do
    test "a #{surface} question cannot erase memory with a newer #{field}",
         %{context: context, path: path} do
      router = router(Actions.callbacks())
      {token, title} = question(router, path, unquote(surface))
      assert title =~ context.original["subject"]
      replacement = Map.put(context.original, unquote(field), context.replacement[unquote(field)])
      MemoryConfirmations.edit!(context, replacement)
      response = post(router, path, token)

      assert %{subject: subject, value: value} = MemoryProjection.fact(context.memory.ref)
      assert %{"subject" => subject, "value" => value} == replacement
      assert response.status == 409
      assert response.resp_body =~ "changed after you opened the page"
    end
  end

  test "a review edit after POST revalidation cannot erase the replacement",
       %{context: context, path: path} do
    actions =
      Map.put(Actions.callbacks(), :forget_memory, fn ref, fingerprint ->
        MemoryConfirmations.edit!(context, context.replacement)
        Memories.forget(ref, fingerprint)
      end)

    router = router(actions)
    {token, _title} = question(router, path, :page)
    response = post(router, path, token)

    assert %{subject: subject, value: value} = MemoryProjection.fact(context.memory.ref)
    assert %{"subject" => subject, "value" => value} == context.replacement
    assert response.status == 409
  end

  for surface <- [:page, :dialog] do
    test "an unchanged #{surface} question forgets exactly the confirmed content",
         %{context: context, path: path} do
      router = router(Actions.callbacks())
      {token, _title} = question(router, path, unquote(surface))
      response = post(router, path, token)
      memory = MemoryConfirmations.fetch!(context)

      assert memory.status == :deleted
      assert memory.payload == %{"forgotten_payload_sha256" => context.memory.payload_fingerprint}
      assert response.status == 303
    end
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
    {token, response.resp_body}
  end

  defp question(router, path, :dialog) do
    assert {:ok, question} = Router.question(path, router)
    {question.token, question.title}
  end

  defp post(router, path, token) do
    form = URI.encode_query(%{"_token" => token})

    Plug.Test.conn(:post, path, form)
    |> Map.put(:host, "localhost")
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(router)
  end
end
