defmodule Ryker.ControlPlane.WebRouter do
  @moduledoc """
  The one route map: every page is a `WorkbenchLive` route, `/assets` is the
  packaged allowlist, signing in is `SignIn`'s, and everything else is
  forwarded to `HttpPlug` for the confirmed actions, downloads, record views
  and observability endpoints. A path answered here is never also answered
  there.
  """
  use Phoenix.Router
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_query_params)
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(Ryker.ControlPlane.Viewer)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {Ryker.ControlPlane.Layouts, :root})
    plug(:answer_missing_records)
  end

  forward("/assets", Ryker.ControlPlane.Assets)

  # The Sign in button posts the one form a route here reads. LiveView carries every other form,
  # and `HttpPlug` reads its own bodies, so nothing before this parses one.
  pipeline :form do
    plug(Plug.Parsers, parsers: [:urlencoded], length: 4_096)
  end

  scope "/" do
    pipe_through([:form, :browser])
    post("/sign-in/:token", Ryker.ControlPlane.SignIn, :use_link)

    post(
      "/github/actions/offer/:ref",
      Ryker.ControlPlane.GitHubActions,
      :confirm_engineering_offer
    )

    post("/github/actions/review/:binding/:number", Ryker.ControlPlane.GitHubActions, :fix_review)
  end

  pipeline :issue_form do
    plug(Plug.Parsers, parsers: [:urlencoded], length: 65_536)
  end

  scope "/" do
    pipe_through([:issue_form, :browser])

    post(
      "/github/actions/issue/:binding/:number",
      Ryker.ControlPlane.GitHubActions,
      :issue_action
    )

    post(
      "/github/actions/issue/:binding/:number/edit",
      Ryker.ControlPlane.GitHubActions,
      :edit_issue_plan
    )
  end

  scope "/" do
    pipe_through(:browser)
    get("/sign-in", Ryker.ControlPlane.SignIn, :page)
    get("/github/actions/results/:turn", Ryker.ControlPlane.GitHubActions, :browser_results)

    get(
      "/github/actions/results/:turn/images/:ref",
      Ryker.ControlPlane.GitHubActions,
      :result_image
    )

    get("/github/actions/offer/:ref", Ryker.ControlPlane.GitHubActions, :engineering_offer)
    get("/github/actions/sign-in", Ryker.ControlPlane.GitHubActions, :sign_in)
    get("/github/actions/callback", Ryker.ControlPlane.GitHubActions, :callback)
    get("/github/actions/issue/:binding/:number", Ryker.ControlPlane.GitHubActions, :issue)

    get(
      "/github/actions/issue/:binding/:number/history/:before",
      Ryker.ControlPlane.GitHubActions,
      :issue
    )

    get(
      "/github/actions/review/:binding/:number/:head/:mode",
      Ryker.ControlPlane.GitHubActions,
      :review
    )

    get("/sign-in/:token", Ryker.ControlPlane.SignIn, :link)
    live("/", Ryker.ControlPlane.WorkbenchLive)

    for path <-
          ~w(conversations activity incident-rooms schedules follow-ups environments skills channels repositories working-copies failures memory rules instructions usage integrations settings setup) do
      live("/#{path}", Ryker.ControlPlane.WorkbenchLive)
    end

    for page <- ~w(learned findings cases people learning) do
      live("/memory/#{page}", Ryker.ControlPlane.WorkbenchLive)
    end

    live("/feedback", Ryker.ControlPlane.WorkbenchLive)
    live("/feedback/fix", Ryker.ControlPlane.WorkbenchLive)

    for page <- ~w(slack github emisar webhooks) do
      live("/integrations/#{page}", Ryker.ControlPlane.WorkbenchLive)
    end

    for page <- ~w(models retention prices report access advanced) do
      live("/settings/#{page}", Ryker.ControlPlane.WorkbenchLive)
    end

    # Each form that adds or edits one thing in a list has a page of its own.
    live("/repositories/new", Ryker.ControlPlane.WorkbenchLive)
    live("/repositories/:ref", Ryker.ControlPlane.WorkbenchLive)
    live("/environments/new", Ryker.ControlPlane.WorkbenchLive)
    live("/skills/install/github", Ryker.ControlPlane.WorkbenchLive)
    live("/skills/:ref", Ryker.ControlPlane.WorkbenchLive)
    live("/environments/:ref/edit", Ryker.ControlPlane.WorkbenchLive)
    live("/settings/models/local-routing", Ryker.ControlPlane.WorkbenchLive)
    live("/settings/models/presets/new", Ryker.ControlPlane.WorkbenchLive)
    live("/settings/models/presets/:item/edit", Ryker.ControlPlane.WorkbenchLive)
    live("/settings/models/accounts/:item/edit", Ryker.ControlPlane.WorkbenchLive)
    live("/settings/prices/new", Ryker.ControlPlane.WorkbenchLive)
    live("/settings/prices/:item/edit", Ryker.ControlPlane.WorkbenchLive)
    live("/integrations/emisar/new", Ryker.ControlPlane.WorkbenchLive)
    live("/integrations/emisar/:ref/edit", Ryker.ControlPlane.WorkbenchLive)
    live("/integrations/webhooks/credentials/new", Ryker.ControlPlane.WorkbenchLive)
    live("/integrations/webhooks/sources/new", Ryker.ControlPlane.WorkbenchLive)
    live("/integrations/webhooks/sources/:item/edit", Ryker.ControlPlane.WorkbenchLive)

    live("/conversations/:id", Ryker.ControlPlane.WorkbenchLive)
    # A record is addressed by its plain id or slug (`Ryker.ControlPlane.Paths`).
    live("/timeline/:id", Ryker.ControlPlane.WorkbenchLive)
    live("/incident-rooms/:slug", Ryker.ControlPlane.WorkbenchLive)
    live("/rules/:id", Ryker.ControlPlane.WorkbenchLive)
    live("/schedules/:id", Ryker.ControlPlane.WorkbenchLive)
    live("/channels/:workspace/:channel", Ryker.ControlPlane.WorkbenchLive)
    live("/failures/:kind/:id", Ryker.ControlPlane.WorkbenchLive)
  end

  # Everything else: actions, downloads, record views and health. A `~p` path
  # that only this forward matches warns, so a verified link always names a
  # page above (`Ryker.ControlPlane.Paths`).
  forward("/", Ryker.ControlPlane.HttpPlug, [], warn_on_verify: true)

  # A record that does not exist answers 404 on the server-rendered load, with
  # the page the browser shows for it. The page's assigns reach the response
  # just before it is sent; live navigation afterwards makes no HTTP request.
  defp answer_missing_records(conn, _options) do
    Plug.Conn.register_before_send(conn, fn conn ->
      if conn.assigns[:page_status] == 404, do: Plug.Conn.put_status(conn, 404), else: conn
    end)
  end
end
