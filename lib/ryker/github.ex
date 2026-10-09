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
  alias Ryker.Secret

  @github "https://github.com"
  @maximum_id 9_223_372_036_854_775_807
  @login ~r/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})\z/
  @repository_name ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
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

  @doc ~s(Whether `value` is a repository's full name on GitHub: "owner/name".)
  @spec repository_name?(term()) :: boolean()
  def repository_name?(value), do: is_binary(value) and Regex.match?(@repository_name, value)

  @doc "Whether `value` is a GitHub numeric id: a positive 64-bit integer."
  @spec id?(term()) :: boolean()
  def id?(value), do: is_integer(value) and value > 0 and value <= @maximum_id

  @doc """
  Whether `value` is a GitHub login: a letter or digit, then up to 38 letters,
  digits or dashes.
  """
  @spec login?(term()) :: boolean()
  def login?(value), do: is_binary(value) and Regex.match?(@login, value)

  @doc """
  Whether `secret` is a sealed webhook secret Ryker checks GitHub's deliveries
  with: 32 to 1,024 bytes.
  """
  @spec webhook_secret?(term()) :: boolean()
  def webhook_secret?(%Secret{value: value}),
    do: is_binary(value) and byte_size(value) in 32..1_024

  def webhook_secret?(_unsealed), do: false

  @doc """
  The owner/name a repository's web page `url` names, or nil when it names
  none: the name people know a repository by, where Ryker keeps a ref.
  """
  @spec repository_name_from_url(String.t() | nil) :: String.t() | nil
  def repository_name_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: "/" <> name} -> if repository_name?(name), do: name
      _other -> nil
    end
  end

  def repository_name_from_url(_url), do: nil

  @doc "The pattern `repository_name?/1` matches, for a changeset's format check."
  @spec repository_name_pattern() :: Regex.t()
  def repository_name_pattern, do: @repository_name

  @doc "The host of `web_url/0`: `github.com`, or the enterprise's."
  @spec web_host() :: String.t()
  def web_host, do: URI.parse(web_url()).host

  @doc "The web page of `repository` (`owner/name`) on the connected GitHub."
  @spec repository_url(String.t()) :: String.t()
  def repository_url(repository), do: web_url() <> "/" <> repository

  defp origin(host, 443), do: "https://" <> host
  defp origin(host, port), do: "https://#{host}:#{port}"
end
