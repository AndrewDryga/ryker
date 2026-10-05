defmodule Ryker.ChildEnvironment do
  @moduledoc """
  The environment of a program Ryker starts: what a program needs to run, and
  nothing else.

  Ryker's own environment holds its master keys (the credential key, the
  state-tools signing token, the database URL), and a program opened with
  `Port.open/2` inherits all of it unless each variable is unset. ffmpeg read
  uploads from anyone in a channel with every one of them (2026-10-04 review).
  """

  @kept ~w(PATH HOME USER LANG LANGUAGE TZ TMPDIR SSL_CERT_FILE SSL_CERT_DIR
           HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy)

  @doc """
  The `:env` option for `Port.open/2`: every variable but the kept ones unset,
  then `set` applied, where `nil` unsets a variable.
  """
  @spec port([{String.t(), String.t() | nil}]) :: [{charlist(), charlist() | false}]
  def port(set \\ []) do
    cleared = for {name, _value} <- System.get_env(), not kept?(name), do: {name, nil}

    (cleared ++ set)
    |> Map.new()
    |> Enum.map(fn
      {name, nil} -> {String.to_charlist(name), false}
      {name, value} -> {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp kept?(name), do: name in @kept or String.starts_with?(name, "LC_")
end
