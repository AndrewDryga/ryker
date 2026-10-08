defmodule Ryker.GitHub do
  @moduledoc """
  Where the GitHub Ryker is connected to lives. Its links, git remotes and
  pull requests are on the web address that goes with the API address the
  App was connected with (`Ryker.Settings.GitHub`): `https://api.github.com`
  is github.com's, `https://<host>/api/v3` a GitHub Enterprise Server's, and
  `https://api.<name>.ghe.com` GitHub Enterprise Cloud's. Every link Ryker
  writes and every pull-request address it accepts is on that host; until
  2026-10-08 they assumed github.com whatever the App was connected to.
  """
  alias Ryker.Config

  @github "https://github.com"
  @github_api "https://api.github.com/"

  @doc """
  The web address of the GitHub whose API is at `api_url`, with no trailing
  slash; github.com's for anything else.
  """
  @spec web_url(String.t() | nil) :: String.t()
  def web_url(api_url) when is_binary(api_url) do
    case URI.parse(api_url) do
      %URI{scheme: "https", host: "api.github.com"} ->
        @github

      %URI{scheme: "https", host: "api." <> host} when host != "" ->
        "https://" <> host

      %URI{scheme: "https", host: host, port: port, path: path} when is_binary(host) ->
        if path |> to_string() |> String.trim_trailing("/") == "/api/v3",
          do: origin(host, port),
          else: @github

      _other ->
        @github
    end
  end

  def web_url(_api_url), do: @github

  @doc """
  The web address of the GitHub the applied settings name
  (`Ryker.Runtime.Assembly` publishes it on each apply).
  """
  @spec web_url() :: String.t()
  def web_url, do: Config.get_env(:github_web_url, @github)

  @doc "`api_url`, as the root its API paths extend: ending in a slash."
  @spec api_root(String.t() | nil) :: String.t()
  def api_root(api_url) when is_binary(api_url), do: String.trim_trailing(api_url, "/") <> "/"
  def api_root(_api_url), do: @github_api

  @doc """
  The API root of the GitHub the applied settings name, ending in a slash
  (`Ryker.Runtime.Assembly` publishes it on each apply).
  """
  @spec api_url() :: String.t()
  def api_url, do: Config.get_env(:github_api_url, @github_api)

  @doc "The host of `web_url/0`: `github.com`, or the enterprise's."
  @spec web_host() :: String.t()
  def web_host, do: URI.parse(web_url()).host

  @doc "The web page of `repository` (`owner/name`) on the connected GitHub."
  @spec repository_url(String.t()) :: String.t()
  def repository_url(repository), do: web_url() <> "/" <> repository

  defp origin(host, 443), do: "https://" <> host
  defp origin(host, port), do: "https://#{host}:#{port}"
end
