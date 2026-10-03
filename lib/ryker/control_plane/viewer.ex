defmodule Ryker.ControlPlane.Viewer do
  @moduledoc """
  Who is using the console, as Tailscale Serve says.

  Served through Tailscale Serve, every request carries the tailnet user's
  login and display name in `Tailscale-User-Login` and `Tailscale-User-Name`,
  and Serve replaces any a client sent itself. The sidebar shows that person
  (Andrew, 2026-10-03: "console shows who is using it, from Tailscale"). It
  grants nothing: what the console may do is still decided by who can reach it.

  A name outside ASCII arrives as RFC 2047 words, the way Serve encodes it.
  """

  @behaviour Plug

  import Plug.Conn

  @type t :: %{login: String.t(), name: String.t()}

  @impl true
  def init(options), do: options

  # The session is written only when the person changes, so an ordinary page
  # load sends no new cookie.
  @impl true
  def call(conn, _options) do
    case {from_headers(conn), get_session(conn, "viewer")} do
      {same, same} -> conn
      {nil, _previous} -> delete_session(conn, "viewer")
      {viewer, _previous} -> put_session(conn, "viewer", viewer)
    end
  end

  @doc "The viewer a LiveView session carries, or nil."
  @spec from_session(map()) :: t() | nil
  def from_session(%{"viewer" => %{"login" => login, "name" => name}})
      when is_binary(login) and is_binary(name),
      do: %{login: login, name: name}

  def from_session(_session), do: nil

  defp from_headers(conn) do
    with [login] <- get_req_header(conn, "tailscale-user-login"),
         {:ok, login} <- text(login, 254) do
      name =
        with [name] <- get_req_header(conn, "tailscale-user-name"),
             {:ok, name} <- text(decode(name), 120) do
          name
        else
          _missing -> login
        end

      %{"login" => login, "name" => name}
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
    ~r/=([0-9A-Fa-f]{2})/
    |> Regex.replace(String.replace(word, "_", " "), fn _match, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end
end
