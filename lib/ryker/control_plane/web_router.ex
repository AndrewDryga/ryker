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
  end

  forward("/assets", Ryker.ControlPlane.Assets)

  scope "/" do
    pipe_through(:browser)
    live("/", Ryker.ControlPlane.WorkbenchLive)

    for path <-
          ~w(conversations activity incident-rooms schedules subscriptions channels repositories failures workspaces findings memory rules preferences guidance instructions usage configuration) do
      live("/#{path}", Ryker.ControlPlane.WorkbenchLive)
    end

    live("/conversations/:id", Ryker.ControlPlane.WorkbenchLive)
    live("/timeline/:ref", Ryker.ControlPlane.WorkbenchLive)
    live("/timeline/:ref/model-calls", Ryker.ControlPlane.WorkbenchLive)
    live("/incident-rooms/:ref", Ryker.ControlPlane.WorkbenchLive)
    live("/schedules/:ref", Ryker.ControlPlane.WorkbenchLive)
    live("/channels/:workspace/:channel", Ryker.ControlPlane.WorkbenchLive)
    live("/failures/:kind/:ref", Ryker.ControlPlane.WorkbenchLive)
  end

  forward("/", Ryker.ControlPlane.HttpPlug)
end
