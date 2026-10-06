defmodule Ryker.ControlPlane.PeoplePageTest do
  # Andrew, 2026-09-30: Ryker learns about people "without approvals". What it
  # learned has to be seen and forgotten somewhere: Memory › People lists
  # everyone, each person's page what Ryker knows and where they said it, and
  # forgetting them asks first and takes effect at once.
  use Ryker.DataCase, async: false
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Actions, Pages, PeoplePage, PeopleProjection, Projection, Router}
  alias Ryker.People
  alias Ryker.People.PersonFact
  alias Ryker.Repo

  test "people are listed with what Ryker knows, each opening their page, and nothing else" do
    fact!("control_plane:user:local-operator", "birthday", "Birthday is 12 March.", false)
    fact!("control_plane:user:local-operator", "preferred-name", "Goes by Andy.", false)

    document =
      render_component(&PeoplePage.render/1, view: PeopleProjection.list())
      |> LazyHTML.from_fragment()

    assert document |> LazyHTML.query(".entity-row") |> LazyHTML.text() =~ "You"
    assert document |> LazyHTML.query(".entity-row") |> LazyHTML.text() =~ "2 things"

    assert document
           |> LazyHTML.query(".entity-row a")
           |> LazyHTML.attribute("href")
           |> Enum.uniq() ==
             ["/memory/people?person=control_plane:user:local-operator"]

    # No kind names or references: what a person reads is what was said.
    refute LazyHTML.text(document) =~ "birthday"
    refute LazyHTML.text(document) =~ "local-operator"
  end

  test "a person's page shows what they said and where, and forgetting them asks first" do
    person = "control_plane:user:local-operator"
    # Said in Chat, a fact stays there (2026-10-04 review).
    fact!(person, "birthday", "Birthday is 12 March.", true)

    assert %{status: 200, title: "You", body: body} =
             Pages.page(["memory", "people"], %{"person" => person}, %{
               projection: Projection.callbacks()
             })

    page = LazyHTML.from_fragment(body)
    assert LazyHTML.text(page) =~ "Birthday is 12 March."
    assert LazyHTML.text(page) =~ "Said in Chat, used only there"
    assert page |> LazyHTML.query("form[method=get] button") |> LazyHTML.text() =~ "Forget"

    path = "/actions/person/#{person}/forget"
    question = confirmation(path)
    assert question.status == 200
    assert question.resp_body =~ "Forget what Ryker learned about you?"

    forgotten = confirm(path)
    assert forgotten.status == 303
    assert Plug.Conn.get_resp_header(forgotten, "location") == ["/memory/people"]

    assert People.about(person, "control-plane:lab:#{Ecto.UUID.generate()}") == []
    assert PeopleProjection.list() == %{people: []}
    assert confirmation(path).status == 404

    assert %{status: 404} =
             Pages.page(["memory", "people"], %{"person" => person}, %{
               projection: Projection.callbacks()
             })
  end

  # Andrew, 2026-09-30, of his own page: "design this page better, and add way to forget
  # individual facts".
  test "each thing a person said can be forgotten on its own, asking first" do
    person = "control_plane:user:local-operator"
    birthday = fact!(person, "birthday", "Birthday is 12 March.", false)
    fact!(person, "preferred-name", "Goes by Andy.", false)

    assert %{status: 200, body: body} =
             Pages.page(["memory", "people"], %{"person" => person}, %{
               projection: Projection.callbacks()
             })

    page = LazyHTML.from_fragment(body)
    rows = LazyHTML.query(page, ".entity-row")
    assert Enum.count(rows) == 2
    assert LazyHTML.text(rows) =~ "Said in Chat"

    forget = "/actions/person-fact/#{birthday.id}/forget"

    assert page |> LazyHTML.query("#fact-#{birthday.id} form") |> LazyHTML.attribute("action") ==
             [forget]

    question = confirmation(forget)
    assert question.status == 200
    assert question.resp_body =~ "Forget &quot;Birthday is 12 March.&quot;?"

    forgotten = confirm(forget)
    assert forgotten.status == 303

    assert Plug.Conn.get_resp_header(forgotten, "location") == [PeoplePage.path(person)]
    assert People.about(person, "control-plane:lab:#{Ecto.UUID.generate()}") == ["Goes by Andy."]
    assert confirmation(forget).status == 404

    # The last one leaves nothing to come back to on this page.
    [name] = People.facts(person)
    last = confirm("/actions/person-fact/#{name.id}/forget")
    assert Plug.Conn.get_resp_header(last, "location") == ["/memory/people"]
  end

  test "an empty page says what will appear there" do
    html = render_component(&PeoplePage.render/1, view: PeopleProjection.list())
    assert html =~ "Nobody yet"
    assert html =~ "their birthday or the name they go by"
  end

  defp fact!(person_ref, key, fact, private) do
    Repo.insert!(%PersonFact{
      id: Ecto.UUID.generate(),
      person_ref: person_ref,
      key: key,
      fact: fact,
      status: :kept,
      source_input_id: Ecto.UUID.generate(),
      source_message_ref: "control-plane-message:#{System.unique_integer([:positive])}",
      # Chat's conversations, as live stores them.
      conversation_ref: "control-plane:lab:#{Ecto.UUID.generate()}",
      private: private,
      said_at: DateTime.utc_now()
    })
  end

  defp confirmation(path) do
    Plug.Test.conn(:get, path)
    |> Map.put(:host, "localhost")
    |> Router.call(router())
  end

  defp confirm(path) do
    page = confirmation(path)
    assert page.status == 200, page.resp_body
    [_, token] = Regex.run(~r/name="_token" value="([^"]+)"/, page.resp_body)

    Plug.Test.conn(:post, path, URI.encode_query(%{"_token" => token}))
    |> Map.put(:host, "localhost")
    |> Plug.Conn.put_req_header("content-type", "application/x-www-form-urlencoded")
    |> Router.call(router())
  end

  defp router do
    Router.init(%{
      csrf_secret: String.duplicate("s", 32),
      actions: Actions.callbacks(),
      observability: %{},
      projection: Projection.callbacks()
    })
  end
end
