defmodule Ryker.ControlPlane.GitHubActionsTest do
  use Ryker.DataCase, async: false
  import Plug.Conn
  import Plug.Test
  alias Ryker.ControlPlane.GitHubActions, as: Page
  alias Ryker.Fixtures.GitHubActions.Requester
  alias Ryker.Settings

  setup do
    {:ok, settings} = Settings.initialize("control-plane:local")

    {:ok, settings} =
      Settings.save_github(
        %{enabled: true, app_id: 1234},
        settings.installation.revision,
        "control-plane:local"
      )

    {:ok, settings} =
      Settings.put_repository(
        %{ref: "widget", github_repository: "acme/widget"},
        settings.installation.revision,
        "control-plane:local"
      )

    {:ok, _settings} =
      Settings.put_github_binding(
        %{
          name: "widget-app",
          repository_ref: "widget",
          installation_id: 41,
          repository_id: 99,
          ryker_actor_id: 4321
        },
        settings.installation.revision,
        "control-plane:local"
      )

    :ok
  end

  test "an authenticated preview renders choices and an empty POST keeps them without queuing work" do
    page = review_conn() |> Page.call({:review, requester: Requester})
    assert page.status == 200
    assert page.resp_body =~ "Choose fixes for PR #42"
    assert page.resp_body =~ "Handle empty input."
    assert page.resp_body =~ "value=\"thread-one\" checked"
    assert page.resp_body =~ "View finding on GitHub"
    assert page.resp_body =~ "aria-live=\"polite\""
    assert page.resp_body =~ "name=\"return_to\""
    snapshot = hidden(page, "snapshot")

    {:ok, snapshot_data} =
      Phoenix.Token.verify(page.secret_key_base, "github-review-selection", snapshot,
        max_age: 3600
      )

    assert snapshot_data.binding == "widget-app"
    assert snapshot_data.number == 42

    empty =
      authenticated_conn(:post, "/github/actions/review/widget-app/42", %{"snapshot" => snapshot})

    empty = %{empty | path_params: %{"binding" => "widget-app", "number" => "42"}}
    response = Page.call(empty, {:fix_review, requester: Requester})
    assert response.status == 409
    assert response.resp_body =~ "Choose at least one finding"
    assert response.resp_body =~ "Handle empty input."
    refute response.resp_body =~ "Review fixes queued"
    refute response.resp_body =~ "value=\"thread-one\" checked"
  end

  test "Fix all explains oversized selections and refuses them without starting work" do
    Process.put(:review_finding_count, 21)

    page =
      review_conn()
      |> put_in([Access.key(:path_params), "mode"], "all")
      |> Page.call({:review, requester: Requester})

    assert page.resp_body =~ "Choose up to 20 findings"

    assert LazyHTML.from_document(page.resp_body)
           |> LazyHTML.query("button[data-fix-selected][disabled]")
           |> Enum.count() == 1

    ids = Enum.map(1..21, &"thread-#{&1}")

    response =
      authenticated_conn(:post, "/github/actions/review/widget-app/42", %{
        "snapshot" => hidden(page, "snapshot"),
        "findings" => ids
      })
      |> Map.put(:path_params, %{"binding" => "widget-app", "number" => "42"})
      |> Page.call({:fix_review, requester: Requester})

    assert response.status == 409
    assert response.resp_body =~ "Choose at most 20 findings for one run"
    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 0
  end

  test "expired sign-in returns to a harmless review GET instead of the POST endpoint" do
    preview = review_conn() |> Page.call({:review, requester: Requester})
    return_to = hidden(preview, "return_to")
    conn = conn(:post, "/github/actions/review/widget-app/42", %{"return_to" => return_to})
    page = %{conn | secret_key_base: String.duplicate("s", 64)} |> Page.call(:fix_review)
    assert page.status == 200
    assert page.resp_body =~ "Continue with GitHub"
    assert hidden(page, "return_to") == return_to
    assert String.ends_with?(return_to, "/selected")
    refute Map.has_key?(page.resp_cookies, "_ryker_github_user")
  end

  test "issue previews are harmless and forged plan versions cannot start work" do
    path = "/github/actions/issue/widget-app/12"

    conn =
      authenticated_conn(:get, path, %{})
      |> Map.put(:path_params, %{"binding" => "widget-app", "number" => "12"})

    page = Page.call(conn, {:issue, requester: Requester})
    assert page.status == 200
    assert page.resp_body =~ "Make a plan"
    assert page.resp_body =~ "Build this"
    assert Repo.aggregate(Ryker.GitHubActions.IssueWorkflow, :count) == 0

    response =
      authenticated_conn(:post, path, %{
        "snapshot" => hidden(page, "snapshot") <> "changed",
        "action" => "build_issue"
      })
      |> Map.put(:path_params, conn.path_params)
      |> Page.call({:issue_action, requester: Requester})

    assert response.status == 409
    assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 0
  end

  defp review_conn do
    head = String.duplicate("a", 40)
    path = "/github/actions/review/widget-app/42/#{head}/selected"
    conn = authenticated_conn(:get, path, %{})

    %{
      conn
      | path_params: %{
          "binding" => "widget-app",
          "number" => "42",
          "head" => head,
          "mode" => "selected"
        }
    }
  end

  defp authenticated_conn(method, path, params) do
    secret = String.duplicate("s", 64)
    session = %{"token" => "writer-token", "expires_at" => System.system_time(:second) + 3600}

    issued =
      conn(:get, "/")
      |> Map.put(:secret_key_base, secret)
      |> put_resp_cookie("_ryker_github_user", session, encrypt: true)
      |> send_resp(200, "")

    conn(method, path, params) |> Map.put(:secret_key_base, secret) |> recycle_cookies(issued)
  end

  defp hidden(page, name) do
    page.resp_body
    |> LazyHTML.from_document()
    |> LazyHTML.query("input[name='#{name}']")
    |> LazyHTML.attribute("value")
    |> hd()
  end
end
