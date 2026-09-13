defmodule Responder.ControlPlane.Assets do
  @moduledoc false
  import Plug.Conn

  @assets %{
    "phoenix.mjs" => {:phoenix, "priv/static/phoenix.mjs", "text/javascript"},
    "phoenix_live_view.esm.js" =>
      {:phoenix_live_view, "priv/static/phoenix_live_view.esm.js", "text/javascript"},
    "control-plane.js" => {:responder, "priv/static/control-plane.js", "text/javascript"},
    "drafts.mjs" => {:responder, "priv/static/drafts.mjs", "text/javascript"},
    "filter-toolbar.mjs" => {:responder, "priv/static/filter-toolbar.mjs", "text/javascript"},
    "history.mjs" => {:responder, "priv/static/history.mjs", "text/javascript"},
    "instruction-draft.mjs" =>
      {:responder, "priv/static/instruction-draft.mjs", "text/javascript"},
    "settings-draft.mjs" => {:responder, "priv/static/settings-draft.mjs", "text/javascript"},
    "relearn-selection.mjs" =>
      {:responder, "priv/static/relearn-selection.mjs", "text/javascript"},
    "control-plane.css" => {:responder, "priv/static/control-plane.css", "text/css"},
    "workspace.css" => {:responder, "priv/static/workspace.css", "text/css"}
  }
  def init(options), do: options

  def call(%{method: "GET", path_info: [asset]} = conn, _options) do
    case @assets[asset] do
      {app, path, type} ->
        conn
        |> put_resp_content_type(type)
        |> send_file(200, Application.app_dir(app, path))
        |> halt()

      nil ->
        conn |> send_resp(404, "Not found") |> halt()
    end
  end

  def call(conn, _options), do: conn |> send_resp(404, "Not found") |> halt()
end
