defmodule Ryker.ControlPlane.CasesPageTest do
  use Ryker.DataCase, async: false
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Phoenix.LiveViewTest

  @endpoint Ryker.ControlPlane.Endpoint

  alias Ryker.ControlPlane.{Actions, CasesPage, CasesProjection, Endpoint, Projection, Router}
  alias Ryker.Memories.CaseRecord

  @now ~U[2026-10-01 12:00:00.000000Z]

  # Nobody could delete a case Ryker kept: a case outlives its request's
  # history, and no page showed one (2026-10-04 review). Cases lists them, and
  # a case's own page forgets it, asking first.
  test "a kept case is listed, opens its own page and is forgotten only after asking first" do
    kept =
      case!("Checkout returns 502 after the deploy",
        cause: "The new pods failed their readiness probe.",
        checked: ["kubectl describe pod checkout-7f9"]
      )

    other = case!("The build runner's disk filled up")

    rows = cases()
    assert counts(rows) == ["2 cases"]

    links = rows |> LazyHTML.query("#case-#{kept.episode_id} a") |> LazyHTML.attribute("href")
    assert Enum.uniq(links) == [CasesPage.path(kept.episode_id)]

    assert {:ok, item} = CasesProjection.fetch(kept.episode_id)
    page = item |> CasesPage.case_html() |> IO.iodata_to_binary()
    assert page =~ "The new pods failed their readiness probe."
    assert page =~ "kubectl describe pod checkout-7f9"
    assert page =~ "Forget case"

    forgotten = confirm("/actions/case/#{kept.episode_id}/forget")
    assert forgotten.status == 303

    assert Plug.Conn.get_resp_header(forgotten, "location") == [
             "/memory/cases?case=#{kept.episode_id}"
           ]

    # The words are gone and later requests no longer read it; that it was
    # kept stays, marked forgotten, and it cannot be forgotten twice.
    assert %CaseRecord{status: :deleted, cause: nil, attempted_actions: []} =
             Repo.one(CaseRecord.Query.by_case_ref(kept.case_ref))

    assert counts(cases()) == ["1 case"]
    assert {:ok, %{forgotten?: true} = gone} = CasesProjection.fetch(kept.episode_id)
    refute gone |> CasesPage.case_html() |> IO.iodata_to_binary() =~ "Forget case"
    assert confirmation("/actions/case/#{kept.episode_id}/forget").status == 404
    assert {:ok, %{forgotten?: false}} = CasesProjection.fetch(other.episode_id)
  end

  test "cases are searched by their problem, cause and how they ended" do
    case!("Checkout returns 502 after the deploy", outcome: "Rolled back to the previous image.")
    case!("The build runner's disk filled up", cause: "Old Docker layers were never pruned.")

    assert counts(cases(%{"q" => "rolled back"})) == ["1 matching"]
    assert counts(cases(%{"q" => "docker layers"})) == ["1 matching"]
    assert cases(%{"q" => "nothing like this"}) |> LazyHTML.text() =~ "No cases match"
  end

  test "an empty Cases page says what puts a case there" do
    assert cases() |> LazyHTML.text() =~ "No cases yet"
  end

  test "a case's own page connects, titled with its problem" do
    kept = case!("**Checkout** returns 502 after the deploy")

    start_supervised!(
      {Endpoint,
       server: false,
       secret_key_base: String.duplicate("s", 64),
       pubsub_server: Ryker.PubSub.Server,
       live_view: [signing_salt: "cases-page-test"],
       check_origin: ["//localhost:4321"],
       url: [host: "localhost", port: 4321],
       control_plane: %{
         actions: Actions.callbacks(),
         projection: Projection.callbacks(),
         observability: %{},
         csrf_secret: String.duplicate("s", 32)
       }}
    )

    conn = build_conn() |> Map.put(:host, "localhost")
    {:ok, view, _html} = live(conn, "/memory/cases?case=#{kept.episode_id}")

    assert page_title(view) == "Checkout returns 502 after the deploy · Ryker"
    assert has_element?(view, ".memory-topic-text strong", "Checkout")
    assert has_element?(view, "#forget-case")

    {:ok, list, _html} = live(conn, "/memory/cases")
    assert has_element?(list, "#case-#{kept.episode_id}")
  end

  defp case!(problem, options \\ []) do
    episode_id = Ecto.UUID.generate()

    Repo.insert!(%CaseRecord{
      id: Ecto.UUID.generate(),
      case_ref: "case:" <> episode_id,
      episode_id: episode_id,
      episode_key: "cases-page:" <> episode_id,
      execution_mode: :live,
      transport: "slack",
      conversation_ref: "slack:TCASES:CALERTS",
      workspace_ref: "slack:TCASES",
      problem: problem,
      cause: options[:cause],
      outcome: options[:outcome],
      attempted_actions: Keyword.get(options, :checked, []),
      search_text: problem,
      status: :active,
      closed_at: @now,
      content_fingerprint: String.duplicate("c", 64),
      inserted_at: @now,
      updated_at: @now
    })
  end

  defp cases(params \\ %{}) do
    render_component(&CasesPage.render/1, view: CasesProjection.list(params))
    |> LazyHTML.from_fragment()
  end

  defp counts(document) do
    document
    |> LazyHTML.query(".kit-counts .kit-count")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.split() |> Enum.join(" ")))
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
