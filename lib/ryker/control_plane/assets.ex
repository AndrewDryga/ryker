defmodule Ryker.ControlPlane.Assets do
  @moduledoc false
  import Plug.Conn

  @assets %{
    "phoenix.mjs" => {:phoenix, "priv/static/phoenix.mjs", "text/javascript"},
    "phoenix_live_view.esm.js" =>
      {:phoenix_live_view, "priv/static/phoenix_live_view.esm.js", "text/javascript"},
    "control-plane.js" => {:ryker, "priv/static/control-plane.js", "text/javascript"},
    "composer.mjs" => {:ryker, "priv/static/composer.mjs", "text/javascript"},
    "conversation.mjs" => {:ryker, "priv/static/conversation.mjs", "text/javascript"},
    "drafts.mjs" => {:ryker, "priv/static/drafts.mjs", "text/javascript"},
    "filter-toolbar.mjs" => {:ryker, "priv/static/filter-toolbar.mjs", "text/javascript"},
    "history.mjs" => {:ryker, "priv/static/history.mjs", "text/javascript"},
    "instruction-draft.mjs" => {:ryker, "priv/static/instruction-draft.mjs", "text/javascript"},
    "leave-guard.mjs" => {:ryker, "priv/static/leave-guard.mjs", "text/javascript"},
    "reading-state.mjs" => {:ryker, "priv/static/reading-state.mjs", "text/javascript"},
    "settings-draft.mjs" => {:ryker, "priv/static/settings-draft.mjs", "text/javascript"},
    "relearn-selection.mjs" => {:ryker, "priv/static/relearn-selection.mjs", "text/javascript"},
    "control-plane.css" => {:ryker, "priv/static/control-plane.css", "text/css"},
    "ryker-tokens.css" => {:ryker, "priv/static/ryker-tokens.css", "text/css"},
    "workspace.css" => {:ryker, "priv/static/workspace.css", "text/css"}
  }

  # Supplied Ryker artwork and supporting fonts, copied unchanged from brand/
  # (fingerprinted by brand/source-manifest.sha256) so a release serves them
  # without the brand checkout or a network font fetch. Their bytes are pinned,
  # so browsers may keep them for a week.
  @brand_assets Map.new(
                  [
                    {"brand/lockup-color.svg", "image/svg+xml"},
                    {"brand/lockup.svg", "image/svg+xml"},
                    {"brand/lockup-reverse.svg", "image/svg+xml"},
                    {"brand/mark-mint.svg", "image/svg+xml"},
                    {"brand/mark.svg", "image/svg+xml"},
                    {"brand/mark-reverse.svg", "image/svg+xml"},
                    {"brand/wordmark.svg", "image/svg+xml"},
                    {"brand/avatar.svg", "image/svg+xml"},
                    {"brand/avatar.png", "image/png"},
                    {"brand/banner.png", "image/png"},
                    {"brand/fonts/IBMPlexSans-Regular.woff2", "font/woff2"},
                    {"brand/fonts/IBMPlexSans-SemiBold.woff2", "font/woff2"},
                    {"brand/fonts/IBMPlexMono-Regular.woff2", "font/woff2"},
                    {"brand/fonts/LICENSE.txt", "text/plain"}
                  ],
                  fn {path, type} -> {path, {:ryker, "priv/static/" <> path, type}} end
                )
  @brand_cache_control "public, max-age=604800"

  def init(options), do: options

  def call(%{method: "GET", path_info: [_ | _] = segments} = conn, _options) do
    asset = Enum.join(segments, "/")

    case @assets[asset] || @brand_assets[asset] do
      {app, path, type} ->
        conn
        |> put_resp_content_type(type, charset(type))
        |> cache_control(asset)
        |> send_file(200, Application.app_dir(app, path))
        |> halt()

      nil ->
        conn |> send_resp(404, "Not found") |> halt()
    end
  end

  def call(conn, _options), do: conn |> send_resp(404, "Not found") |> halt()

  defp charset("text/" <> _), do: "utf-8"
  defp charset("image/svg+xml"), do: "utf-8"
  defp charset(_binary), do: nil

  defp cache_control(conn, "brand/" <> _),
    do: put_resp_header(conn, "cache-control", @brand_cache_control)

  defp cache_control(conn, _asset), do: conn
end
