defmodule Ryker.ControlPlane.PublicPage do
  @moduledoc "Shared rendering for sign-in and repository action pages. Callers escape every body value."
  import Plug.Conn
  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.Layouts

  # `Layouts.sign_in/1` renders through HEEx, which escapes the title; bodies are this module's
  # markup, escaping every value.
  # sobelow_skip ["XSS.SendResp"]
  def page(conn, status, title, body) do
    html =
      %{__changed__: nil, title: title, body: IO.iodata_to_binary(body)}
      |> Layouts.sign_in()
      |> Safe.to_iodata()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
    |> halt()
  end

  def go(conn, path) do
    conn
    |> put_resp_header("location", path)
    |> send_resp(303, "")
    |> halt()
  end

  def escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  def csrf do
    [
      "<input type=\"hidden\" name=\"_csrf_token\" value=\"",
      escape(Plug.CSRFProtection.get_csrf_token()),
      "\">"
    ]
  end
end
