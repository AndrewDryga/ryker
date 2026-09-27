defmodule Ryker.ControlPlane.WebRouter do
  @moduledoc """
  The one route map: every page is a `WorkbenchLive` route, `/assets` is the
  packaged allowlist, and everything else is forwarded to `HttpPlug` for the
  confirmed actions, downloads, record views and observability endpoints.
  A path answered here is never also answered there.
  """
  use Phoenix.Router
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_query_params)
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {Ryker.ControlPlane.Layouts, :root})
    plug(:answer_missing_records)
  end

  forward("/assets", Ryker.ControlPlane.Assets)

  scope "/" do
    pipe_through(:browser)
    live("/", Ryker.ControlPlane.WorkbenchLive)

    for path <-
          ~w(conversations activity incident-rooms schedules follow-ups environments channels repositories working-copies failures memory rules instructions usage integrations settings setup) do
      live("/#{path}", Ryker.ControlPlane.WorkbenchLive)
    end

    for page <- ~w(learned findings learning feedback) do
      live("/memory/#{page}", Ryker.ControlPlane.WorkbenchLive)
    end

    live("/memory/feedback/fix", Ryker.ControlPlane.WorkbenchLive)

    for page <- ~w(slack github emisar webhooks) do
      live("/integrations/#{page}", Ryker.ControlPlane.WorkbenchLive)
    end

    for page <- ~w(models retention prices advanced) do
      live("/settings/#{page}", Ryker.ControlPlane.WorkbenchLive)
    end

    # Each form that adds or edits one thing in a list has a page of its own.
    live("/repositories/new", Ryker.ControlPlane.WorkbenchLive)
    live("/environments/new", Ryker.ControlPlane.WorkbenchLive)
    live("/environments/:ref/edit", Ryker.ControlPlane.WorkbenchLive)
    live("/settings/prices/new", Ryker.ControlPlane.WorkbenchLive)
    live("/settings/prices/:item/edit", Ryker.ControlPlane.WorkbenchLive)
    live("/integrations/emisar/new", Ryker.ControlPlane.WorkbenchLive)
    live("/integrations/emisar/:ref/edit", Ryker.ControlPlane.WorkbenchLive)
    live("/integrations/webhooks/credentials/new", Ryker.ControlPlane.WorkbenchLive)
    live("/integrations/webhooks/sources/new", Ryker.ControlPlane.WorkbenchLive)
    live("/integrations/webhooks/sources/:item/edit", Ryker.ControlPlane.WorkbenchLive)

    live("/conversations/:id", Ryker.ControlPlane.WorkbenchLive)
    live("/timeline/:ref", Ryker.ControlPlane.WorkbenchLive)
    live("/incident-rooms/:ref", Ryker.ControlPlane.WorkbenchLive)
    live("/schedules/:ref", Ryker.ControlPlane.WorkbenchLive)
    live("/channels/:workspace/:channel", Ryker.ControlPlane.WorkbenchLive)
    live("/failures/:kind/:ref", Ryker.ControlPlane.WorkbenchLive)
  end

  forward("/", Ryker.ControlPlane.HttpPlug)

  # A record that does not exist answers 404 on the server-rendered load, with
  # the page the browser shows for it. The page's assigns reach the response
  # just before it is sent; live navigation afterwards makes no HTTP request.
  @doc false
  def answer_missing_records(conn, _options) do
    Plug.Conn.register_before_send(conn, fn conn ->
      if conn.assigns[:page_status] == 404, do: Plug.Conn.put_status(conn, 404), else: conn
    end)
  end
end
