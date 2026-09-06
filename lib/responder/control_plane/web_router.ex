defmodule Responder.ControlPlane.WebRouter do
  @moduledoc false
  use Phoenix.Router
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
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
          ~w(lab card-lab episodes incidents schedules subscriptions channels repositories failures workspaces decisions findings memory rules preferences guidance calibration usage configuration manual-tests) do
      live("/#{path}", Responder.ControlPlane.WorkbenchLive)
    end

    live("/lab/:id", Responder.ControlPlane.WorkbenchLive)
    live("/card-lab/:card/:state", Responder.ControlPlane.WorkbenchLive)
    live("/episodes/:ref", Responder.ControlPlane.WorkbenchLive)
    live("/episodes/:ref/requests", Responder.ControlPlane.WorkbenchLive)
    live("/incidents/:ref", Responder.ControlPlane.WorkbenchLive)
    live("/schedules/:ref", Responder.ControlPlane.WorkbenchLive)
    live("/channels/:workspace/:channel", Responder.ControlPlane.WorkbenchLive)
    live("/failures/:kind/:ref", Responder.ControlPlane.WorkbenchLive)
  end

  forward("/", Responder.ControlPlane.LegacyPlug)
end
