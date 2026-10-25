defmodule Ryker.ControlPlane.FactForgettingConfirmationTest do
  use Ryker.DataCase, async: false
  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{Actions, Projection, Router}
  alias Ryker.Fixtures.People, as: PeopleFixtures
  alias Ryker.People

  setup do
    context = PeopleFixtures.retained_context!()
    [original, replacement | _] = context.items
    source = Enum.find(context.entries, &(&1.id == replacement["source_input_id"]))
    later = PeopleFixtures.later_entry!(context, source, 60)

    replacement =
      replacement |> Map.put("key", original["key"]) |> Map.put("source_input_id", later.id)

    learn!(context.entries, [original])
    [fact] = People.facts(context.person)

    %{
      context: context,
      original: original,
      replacement: replacement,
      later: later,
      fact: fact,
      path: "/actions/person-fact/#{fact.id}/forget"
    }
  end

  # The row is reused when learning replaces a kind. Its id-only token still
  # approved Forget after the quoted words changed, erasing an unreviewed fact.
  for surface <- [:page, :dialog] do
    test "a #{surface} confirmation cannot erase a fact learned after its quoted sentence",
         %{
           context: context,
           original: original,
           replacement: replacement,
           later: later,
           path: path
         } do
      router = router(Actions.callbacks())
      {token, question} = question(router, path, unquote(surface))
      assert question =~ original["fact"]
      learn!([later], [replacement])
      response = post(router, path, token)

      assert People.about(context.person, context.conversation) == [replacement["fact"]]
      assert response.status == 409
      assert response.resp_body =~ "changed after you opened the page"
    end
  end

  test "a fact changed after POST revalidation is still protected by the action",
       %{context: context, replacement: replacement, later: later, path: path} do
    actions =
      Map.put(Actions.callbacks(), :forget_person_fact, fn id, expected_digest ->
        learn!([later], [replacement])
        People.forget_fact(id, expected_digest)
      end)

    router = router(actions)
    {token, _question} = question(router, path, :page)
    response = post(router, path, token)

    assert People.about(context.person, context.conversation) == [replacement["fact"]]
    assert response.status == 409
    assert response.resp_body =~ "changed after you opened the page"
  end

  test "the quoted sentence can still be forgotten when a fresh source repeats it",
       %{context: context, original: original, later: later, path: path} do
    router = router(Actions.callbacks())
    {token, _question} = question(router, path, :dialog)
    repeated = Map.put(original, "source_input_id", later.id)
    learn!([later], [repeated])
    response = post(router, path, token)

    assert People.about(context.person, context.conversation) == []
    assert response.status == 303
  end

  test "a refused sentence does not withdraw earlier sources",
       %{context: context, original: original, replacement: replacement, later: later, fact: fact} do
    expected_digest = CanonicalJSON.digest(fact.fact)
    learn!([later], [replacement])
    result = People.forget_fact(fact.id, expected_digest)
    replay = Map.put(original, "key", "recalled-statement")
    learn!(context.entries, [replay])

    assert Enum.sort(People.about(context.person, context.conversation)) ==
             Enum.sort([original["fact"], replacement["fact"]])

    assert result == {:error, :confirmation_stale}
  end

  test "an invalid expected sentence refuses without erasing anything",
       %{context: context, original: original, fact: fact} do
    for invalid <- [nil, "not-a-digest", String.duplicate("a", 64)] do
      result = People.forget_fact(fact.id, invalid)

      assert People.about(context.person, context.conversation) == [original["fact"]]
      assert result == {:error, :confirmation_stale}
    end
  end

  # Forget erases every identical copy. Counting rows as "other facts" left
  # the success redirect pointing at a person page that no longer existed.
  for other <- [false, true] do
    test "forgetting copies returns to #{if other, do: "the remaining person", else: "everyone"}",
         %{context: context, original: original, path: path} do
      duplicate = Map.put(original, "key", "repeated-statement")
      [_original, different | _] = context.items
      items = if unquote(other), do: [duplicate, different], else: [duplicate]
      learn!(context.entries, items)
      router = router(Actions.callbacks())
      {token, _question} = question(router, path, :page)
      response = post(router, path, token)

      destination =
        if unquote(other),
          do: Ryker.ControlPlane.PeoplePage.path(context.person),
          else: "/memory/people"

      assert Plug.Conn.get_resp_header(response, "location") == [destination]
      assert response.status == 303

      assert People.about(context.person, context.conversation) ==
               if(unquote(other), do: [different["fact"]], else: [])
    end
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

  defp router(actions) do
    Router.init(%{
      csrf_secret: String.duplicate("s", 32),
      actions: actions,
      observability: %{},
      projection: Projection.callbacks()
    })
  end

  defp learn!(entries, items) do
    assert Repo.transaction(fn -> People.learn_in_transaction(items, entries) end) == {:ok, :ok}
  end
end
