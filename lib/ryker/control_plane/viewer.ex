defmodule Ryker.ControlPlane.Viewer do
  @moduledoc """
  Who is using the console: the person a request or a page is signed in as, or nobody.

  Ryker signs people in itself (`Ryker.ConsoleAccess`): a browser a sign-in link signed in
  carries its session's token in the console's cookie, and is that link's person while the
  session lasts. The services that carry the console to a browser can name a person too, and
  when they do, nobody needs a link:

  - Published through Cloudflare Access, every request carries the signed-in person's Access
    token, and the person is its email once the token checks out (`CloudflareAccess`).
  - Served through Tailscale Serve, every request carries the tailnet user's login and display
    name in `Tailscale-User-Login` and `Tailscale-User-Name`, and Serve replaces any a client
    sent itself (Andrew, 2026-10-03: "console shows who is using it, from Tailscale").

  Serve's headers are not signed. They are read only at the published host, and only when that
  host is a Tailscale name (`.ts.net`), which no Cloudflare tunnel or other proxy can route: a
  request that came any other way and carried them would name whoever it liked. Access tokens
  are signed, so under Access only a token Cloudflare issued names anyone. A request at a
  loopback name is named only by its session.

  The sidebar shows the person, and what they change is recorded as theirs
  (`Ryker.ControlPlane.Actor`). A name outside ASCII arrives as RFC 2047 words, the way Serve
  encodes it.
  """
  @behaviour Plug
  import Plug.Conn
  alias Ryker.ConsoleAccess
  alias Ryker.ControlPlane.{Actor, CloudflareAccess, Endpoint}

  # `until`: the Unix second an Access sign-in stops counting. `session_id`: the console session
  # a sign-in link started.
  @type t :: %{
          required(:login) => String.t(),
          required(:name) => String.t(),
          required(:via) => :tailscale | :cloudflare | :slack_operator | :invite | :owner,
          optional(:until) => integer(),
          optional(:session_id) => Ecto.UUID.t()
        }

  @session_key "console_session"
  @resolved :ryker_viewer

  @impl true
  def init(options), do: options

  # A person a service named is kept in the session for the page's live socket, written only
  # when the person changes, so an ordinary page load sends no new cookie. A session's own
  # person is read from its token, which the session already holds.
  @impl true
  def call(conn, _options) do
    conn = fetch_session(conn)

    case {stored(published(conn)), get_session(conn, "viewer")} do
      {same, same} -> conn
      {nil, _previous} -> delete_session(conn, "viewer")
      {viewer, _previous} -> put_session(conn, "viewer", viewer)
    end
  end

  @doc "The session key a signed-in browser's token is kept under."
  @spec session_key() :: String.t()
  def session_key, do: @session_key

  @doc """
  Who a request is: the person a service that published the console named on it, or the
  person its session is signed in as, or nil. Read once per request: the sign-in gate keeps
  what it read on the connection, and everything after it reads that.
  """
  @spec from_conn(Plug.Conn.t(), map()) :: t() | nil
  def from_conn(%Plug.Conn{private: %{@resolved => viewer}}, _control_plane), do: viewer

  def from_conn(conn, control_plane) do
    published(conn, control_plane) || from_token(session_token(conn))
  end

  @doc "The request, carrying who it is (`from_conn/2`), so nothing after it reads that again."
  @spec resolved(Plug.Conn.t(), t() | nil) :: Plug.Conn.t()
  def resolved(conn, viewer), do: put_private(conn, @resolved, viewer)

  @doc "What an action this request takes is recorded as."
  @spec actor_ref(Plug.Conn.t(), map()) :: String.t()
  def actor_ref(conn, control_plane), do: conn |> from_conn(control_plane) |> Actor.of()

  @doc "The person a page's session is signed in as, or nil."
  @spec from_session(map()) :: t() | nil
  def from_session(%{"viewer" => %{"login" => login, "name" => name, "via" => "tailscale"}})
      when is_binary(login) and is_binary(name),
      do: %{login: login, name: name, via: :tailscale}

  def from_session(%{
        "viewer" => %{"login" => login, "name" => name, "via" => "cloudflare", "until" => until}
      })
      when is_binary(login) and is_binary(name) and is_integer(until),
      do: %{login: login, name: name, via: :cloudflare, until: until}

  def from_session(%{@session_key => token}), do: from_token(token)
  def from_session(_session), do: nil

  @doc "Whether the person can sign out: only a sign-in link's session ends when they do."
  @spec signed_in_by_link?(t() | nil) :: boolean()
  def signed_in_by_link?(%{session_id: id}) when is_binary(id), do: true
  def signed_in_by_link?(_viewer), do: false

  defp published(conn), do: published(conn, Endpoint.config(:control_plane))

  # Only a request at the published host is read for a person a service named.
  defp published(%Plug.Conn{host: host} = conn, %{public_host: host} = control_plane)
       when is_binary(host) do
    case Map.get(control_plane, :cloudflare_access) do
      nil ->
        if tailscale_host?(host), do: from_headers(conn)

      access ->
        case CloudflareAccess.viewer(conn, access) do
          {:ok, viewer} -> viewer
          :error -> nil
        end
    end
  end

  defp published(_conn, _control_plane), do: nil

  defp tailscale_host?(host), do: String.ends_with?(String.downcase(host), ".ts.net")

  defp session_token(%Plug.Conn{private: %{plug_session_fetch: :done}} = conn),
    do: get_session(conn, @session_key)

  defp session_token(_conn), do: nil

  defp from_token(token) when is_binary(token) do
    case ConsoleAccess.fetch_session(token) do
      {:ok, session} ->
        %{
          login: session.person_login,
          name: session.person_name,
          via: session.person_via,
          session_id: session.id
        }

      {:error, _not_found} ->
        nil
    end
  end

  defp from_token(_token), do: nil

  defp stored(nil), do: nil

  defp stored(%{login: login, name: name, via: :cloudflare, until: until}),
    do: %{"login" => login, "name" => name, "via" => "cloudflare", "until" => until}

  defp stored(%{login: login, name: name, via: :tailscale}),
    do: %{"login" => login, "name" => name, "via" => "tailscale"}

  # A login is an email-like address; 200 bytes keeps the actor it becomes
  # within what every record of an actor holds.
  defp from_headers(conn) do
    with [login] <- get_req_header(conn, "tailscale-user-login"),
         {:ok, login} <- text(login, 200) do
      name =
        with [name] <- get_req_header(conn, "tailscale-user-name"),
             {:ok, name} <- text(decode(name), 120) do
          name
        else
          _missing -> login
        end

      %{login: login, name: name, via: :tailscale}
    else
      _missing -> nil
    end
  end

  defp text(value, maximum) do
    value = String.trim(value)

    if value != "" and byte_size(value) <= maximum and String.valid?(value) and
         not Regex.match?(~r/[\x00-\x1F\x7F]/, value),
       do: {:ok, value},
       else: :error
  end

  # `=?utf-8?q?Zo=C3=AB_Smith?=`: underscores are spaces, =XX a byte, and the
  # space between two encoded words is not part of the text.
  defp decode(value) do
    words = Regex.scan(~r/=\?utf-8\?q\?([^?]*)\?=/i, value, capture: :all_but_first)

    if words == [] do
      value
    else
      Enum.map_join(words, fn [word] -> unquote_word(word) end)
    end
  end

  defp unquote_word(word) do
    spaced = String.replace(word, "_", " ")

    Regex.replace(~r/=([0-9A-Fa-f]{2})/, spaced, fn _match, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end
end
