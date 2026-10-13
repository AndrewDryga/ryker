defmodule Ryker.ConsoleSignIn do
  @moduledoc """
  A browser signed in to the console, for page tests. Nobody uses the console without signing
  in (`Ryker.ControlPlane.SignInGate`), so a page test signs in the way a person does: a link
  from Slack, used once, whose session the browser's cookie holds.
  """
  import Phoenix.ConnTest, only: [build_conn: 0]
  import Plug.Test, only: [init_test_session: 2]
  alias Ryker.ConsoleAccess

  @doc "What the console records the person `signed_in_conn/1` signs in as."
  @spec actor() :: String.t()
  def actor, do: "control-plane:slack_operator:TCONSOLE.UCONSOLE"

  @doc "What Chat records the person `signed_in_conn/1` signs in as (`Actor.chat_ref/1`)."
  @spec chat_ref() :: String.t()
  def chat_ref, do: "slack_operator:TCONSOLE.UCONSOLE"

  @doc "A connection whose session is signed in as `name`, an operator from Slack."
  @spec signed_in_conn(String.t()) :: Plug.Conn.t()
  def signed_in_conn(name \\ "Test operator") do
    init_test_session(build_conn(), %{"console_session" => session_token(name)})
  end

  @doc "The token of a fresh session signed in as `name`, as a browser's cookie holds it."
  @spec session_token(String.t()) :: String.t()
  def session_token(name \\ "Test operator") do
    {:ok, url} = ConsoleAccess.slack_link("TCONSOLE", "UCONSOLE", name)
    "/sign-in/" <> token = URI.parse(url).path
    {:ok, session_token, _session, _link} = ConsoleAccess.sign_in(token)
    session_token
  end
end
