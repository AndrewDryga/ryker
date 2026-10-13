defmodule Ryker.ControlPlane.SignIn do
  @moduledoc """
  Signing in to the console (`Ryker.ConsoleAccess`): the page that says how, and the page a
  sign-in link opens.

  A link signs its person in only when they press Sign in on its page. Opening it changes
  nothing, because Slack and other chat apps open a link to preview it before anyone clicks.
  A link that worked starts a session for this browser and opens the page the person asked for
  before signing in, or the one the link was made for.
  """
  @behaviour Plug
  import Plug.Conn
  alias Phoenix.HTML.Safe
  alias Ryker.ConsoleAccess
  alias Ryker.ControlPlane.{Layouts, SignInGate, Viewer}

  @impl true
  def init(action) when action in [:page, :link, :use_link], do: action

  @impl true
  def call(conn, :page) do
    case Viewer.from_conn(conn, %{}) do
      nil -> conn |> delete_session(Viewer.session_key()) |> page(200, "Sign in to Ryker", how())
      _viewer -> go(conn, "/")
    end
  end

  def call(%Plug.Conn{path_params: %{"token" => token}} = conn, :link) do
    case ConsoleAccess.fetch_link(token) do
      {:ok, link} -> page(conn, 200, "Sign in to Ryker", confirm(link, conn.request_path))
      {:error, reason} -> refused(conn, reason, token)
    end
  end

  def call(%Plug.Conn{path_params: %{"token" => token}} = conn, :use_link) do
    case ConsoleAccess.sign_in(token) do
      {:ok, session_token, session, link} ->
        destination = link.return_to || get_session(conn, SignInGate.return_key()) || "/"

        conn
        |> configure_session(renew: true)
        |> clear_session()
        |> put_session(Viewer.session_key(), session_token)
        |> put_session("live_socket_id", "console_session:" <> session.id)
        |> go(if SignInGate.return_path?(destination), do: destination, else: "/")

      {:error, reason} ->
        refused(conn, reason, token)
    end
  end

  defp refused(conn, :not_found, _token) do
    page(conn, 404, "This link doesn't work", [
      "<p>It may have been withdrawn, or copied only in part. ",
      "Ask Ryker for a new one: send <code>/ryker sign-in</code> in Slack. ",
      "If someone invited you, ask them for a new invite.</p>"
    ])
  end

  defp refused(conn, reason, token) do
    {title, opening} =
      case reason do
        :used -> {"This link was used already", "A link signs in once."}
        _expired -> {"This link has expired", "It no longer signs anyone in."}
      end

    page(conn, 410, title, ["<p>", opening, " ", again(token), "</p>"])
  end

  # Where a new link comes from, for the link that was opened.
  defp again(token) do
    case ConsoleAccess.link_kind(token) do
      :invite ->
        "Ask whoever invited you for a new one."

      :owner ->
        "Run <code>scripts/compose.sh sign-in</code> on the machine Ryker runs on for a new one."

      _slack ->
        "Ask Ryker for a new one: send <code>/ryker sign-in</code> in Slack."
    end
  end

  defp how do
    [
      "<p>Ryker's operators sign in from Slack. Send Ryker <code>/ryker sign-in</code>, or open ",
      "Ryker's App Home and press <strong>Open the console</strong>. Ryker replies with a link ",
      "that signs you in on this browser.</p>",
      "<p>Not one of Ryker's operators? Ask someone who is signed in to invite you.</p>",
      "<p class=\"sign-in-note\">On the machine Ryker runs on, ",
      "<code>scripts/compose.sh sign-in</code> prints a link too.</p>"
    ]
  end

  defp confirm(link, action) do
    [
      "<p>This link signs you in as <strong>",
      escape(link.person_name),
      "</strong> on this browser. It works once.</p>",
      "<form method=\"post\" action=\"",
      escape(action),
      "\"><input type=\"hidden\" name=\"_csrf_token\" value=\"",
      escape(Plug.CSRFProtection.get_csrf_token()),
      "\"><button class=\"ui-button primary\" type=\"submit\">Sign in</button></form>"
    ]
  end

  # `Layouts.sign_in/1` renders through HEEx, which escapes the title; bodies are this module's
  # markup, escaping every value.
  # sobelow_skip ["XSS.SendResp"]
  defp page(conn, status, title, body) do
    html =
      %{__changed__: nil, title: title, body: IO.iodata_to_binary(body)}
      |> Layouts.sign_in()
      |> Safe.to_iodata()

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, html)
    |> halt()
  end

  defp go(conn, path) do
    conn
    |> put_resp_header("location", path)
    |> send_resp(303, "")
    |> halt()
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
