defmodule Responder.ControlPlane.WebRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_query_params)
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {Responder.ControlPlane.Layouts, :root})
  end

  forward("/assets", Responder.ControlPlane.Assets)
  get("/lab/new", Responder.ControlPlane.LegacyPlug, :new)

  scope "/" do
    pipe_through(:browser)
    live("/", Responder.ControlPlane.WorkbenchLive)

    for path <-
          ~w(lab card-lab activity incident-rooms schedules subscriptions channels repositories failures workspaces findings memory rules preferences guidance instructions usage configuration manual-tests) do
      live("/#{path}", Responder.ControlPlane.WorkbenchLive)
    end

    live("/lab/:id", Responder.ControlPlane.WorkbenchLive)
    live("/card-lab/:card/:state", Responder.ControlPlane.WorkbenchLive)
    live("/timeline/:ref", Responder.ControlPlane.WorkbenchLive)
    live("/timeline/:ref/model-calls", Responder.ControlPlane.WorkbenchLive)
    live("/incident-rooms/:ref", Responder.ControlPlane.WorkbenchLive)
    live("/schedules/:ref", Responder.ControlPlane.WorkbenchLive)
    live("/channels/:workspace/:channel", Responder.ControlPlane.WorkbenchLive)
    live("/failures/:kind/:ref", Responder.ControlPlane.WorkbenchLive)
  end

  forward("/", Responder.ControlPlane.LegacyPlug)
end
