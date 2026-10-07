defmodule Ryker.ControlPlane.Assets do
  @moduledoc false
  import Plug.Conn
  alias Ryker.Crypto

  @assets %{
    "phoenix.mjs" => {:phoenix, "priv/static/phoenix.mjs", "text/javascript"},
    "phoenix_live_view.esm.js" =>
      {:phoenix_live_view, "priv/static/phoenix_live_view.esm.js", "text/javascript"},
    "control-plane.js" => {:ryker, "priv/static/control-plane.js", "text/javascript"},
    "copy-value.mjs" => {:ryker, "priv/static/copy-value.mjs", "text/javascript"},
    "composer.mjs" => {:ryker, "priv/static/composer.mjs", "text/javascript"},
    "conversation.mjs" => {:ryker, "priv/static/conversation.mjs", "text/javascript"},
    "drafts.mjs" => {:ryker, "priv/static/drafts.mjs", "text/javascript"},
    "elapsed-time.mjs" => {:ryker, "priv/static/elapsed-time.mjs", "text/javascript"},
    "filter-toolbar.mjs" => {:ryker, "priv/static/filter-toolbar.mjs", "text/javascript"},
    "filter-menu.mjs" => {:ryker, "priv/static/filter-menu.mjs", "text/javascript"},
    "history.mjs" => {:ryker, "priv/static/history.mjs", "text/javascript"},
    "instruction-draft.mjs" => {:ryker, "priv/static/instruction-draft.mjs", "text/javascript"},
    "leave-guard.mjs" => {:ryker, "priv/static/leave-guard.mjs", "text/javascript"},
    "page-help.mjs" => {:ryker, "priv/static/page-help.mjs", "text/javascript"},
    "page-help-early.js" => {:ryker, "priv/static/page-help-early.js", "text/javascript"},
    "tooltips.mjs" => {:ryker, "priv/static/tooltips.mjs", "text/javascript"},
    "prompt-parts.mjs" => {:ryker, "priv/static/prompt-parts.mjs", "text/javascript"},
    "reading-state.mjs" => {:ryker, "priv/static/reading-state.mjs", "text/javascript"},
    "settings-draft.mjs" => {:ryker, "priv/static/settings-draft.mjs", "text/javascript"},
    "relearn-selection.mjs" => {:ryker, "priv/static/relearn-selection.mjs", "text/javascript"},
    "repository-picker.mjs" => {:ryker, "priv/static/repository-picker.mjs", "text/javascript"},
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
      {app, path, type} -> serve(conn, asset, Application.app_dir(app, path), type)
      nil -> conn |> send_resp(404, "Not found") |> halt()
    end
  end

  def call(conn, _options), do: conn |> send_resp(404, "Not found") |> halt()

  # Every page load downloaded the scripts and stylesheets again, about 650 KB
  # uncompressed, under the no-store every response leaves BrowserGuard with
  # (2026-10-04). Each file now carries an ETag of its bytes: the browser keeps
  # it and asks whether it changed, and an unchanged file costs a 304 with no
  # body. Text goes gzipped to a browser that accepts it.
  #
  # The compressed bytes are a representation of their own with a tag of their
  # own: one tag for both let a cache holding the compressed copy answer a
  # browser that cannot unpack it with a 304 (2026-10-04 review).
  defp serve(conn, asset, file, type) do
    %{etag: etag, plain: plain, gzip: gzip} = prepared(file, type)

    {etag, body, encoding} =
      if is_binary(gzip) and accepts_gzip?(conn),
        do: {String.replace_suffix(etag, ~s("), ~s(-gzip")), gzip, "gzip"},
        else: {etag, plain, nil}

    conn =
      conn
      |> put_resp_content_type(type, charset(type))
      |> cache_control(asset)
      |> put_resp_header("etag", etag)
      |> put_resp_header("vary", "accept-encoding")

    cond do
      etag in if_none_match(conn) ->
        conn |> send_resp(304, "") |> halt()

      encoding ->
        conn |> put_resp_header("content-encoding", encoding) |> send_resp(200, body) |> halt()

      true ->
        conn |> send_resp(200, body) |> halt()
    end
  end

  # A release's files never change while it runs, so each is read, tagged and
  # compressed once.
  defp prepared(file, type) do
    key = {__MODULE__, file}

    case :persistent_term.get(key, nil) do
      nil ->
        plain = File.read!(file)
        digest = Crypto.sha256_hex(plain) |> binary_part(0, 32)

        prepared = %{
          etag: ~s("#{digest}"),
          plain: plain,
          gzip: if(charset(type), do: :zlib.gzip(plain))
        }

        :persistent_term.put(key, prepared)
        prepared

      prepared ->
        prepared
    end
  end

  defp if_none_match(conn) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> String.replace_prefix("W/", "")))
  end

  # Accept-Encoding names each coding with an optional weight, and a weight of
  # zero refuses it: "gzip;q=0" counted as accepting gzip (2026-10-04 review).
  # gzip is accepted by name, or by "*" when gzip is not named.
  defp accepts_gzip?(conn) do
    weights =
      conn
      |> get_req_header("accept-encoding")
      |> Enum.flat_map(&String.split(&1, ","))
      |> Map.new(&coding_weight/1)

    Map.get(weights, "gzip", Map.get(weights, "*", 0.0)) > 0.0
  end

  defp coding_weight(part) do
    [coding | parameters] = part |> String.downcase() |> String.split(";")

    weight =
      Enum.find_value(parameters, 1.0, fn parameter ->
        case String.split(String.trim(parameter), "=", parts: 2) do
          ["q", value] -> parse_weight(value)
          _other -> nil
        end
      end)

    {String.trim(coding), weight}
  end

  defp parse_weight(value) do
    case Float.parse(String.trim(value)) do
      {weight, ""} -> weight
      _invalid -> 0.0
    end
  end

  defp charset("text/" <> _), do: "utf-8"
  defp charset("image/svg+xml"), do: "utf-8"
  defp charset(_binary), do: nil

  defp cache_control(conn, "brand/" <> _),
    do: put_resp_header(conn, "cache-control", @brand_cache_control)

  defp cache_control(conn, _asset), do: put_resp_header(conn, "cache-control", "no-cache")
end
