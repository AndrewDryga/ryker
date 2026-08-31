defmodule Responder.Publication.GitCommand do
  @moduledoc """
  Runs one bounded, hermetic Git command.

  The ambient process environment is removed except for an explicit transport
  allowlist. Authentication is passed only through the child environment, not
  through argv, a URL, a credential helper, or a file.
  """

  @behaviour Responder.Publication.GitCommandAPI

  @maximum_output_bytes 1 * 1_024 * 1_024
  @default_timeout_ms 30_000
  @passthrough ~w(PATH HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy SSL_CERT_FILE SSL_CERT_DIR GIT_SSL_CAINFO GIT_SSL_CAPATH)

  @impl true
  def run(directory, arguments, options \\ []) do
    timeout_ms = Keyword.get(options, :timeout_ms, @default_timeout_ms)
    extra_env = Keyword.get(options, :env, [])

    with true <- absolute_directory?(directory),
         true <- valid_arguments?(arguments),
         true <- is_integer(timeout_ms) and timeout_ms > 0,
         true <- valid_env?(extra_env),
         git when is_binary(git) <- System.find_executable("git") do
      port =
        Port.open(
          {:spawn_executable, git},
          [
            :binary,
            :exit_status,
            :hide,
            :stderr_to_stdout,
            args: arguments,
            cd: directory,
            env: environment(directory, extra_env)
          ]
        )

      collect(port, timeout_ms, [], 0)
    else
      false -> {:error, {:invalid_publication_git_command, :arguments}}
      nil -> {:error, {:publication_git_unavailable, :executable}}
    end
  rescue
    error -> {:error, {:publication_git_command_failed, Exception.message(error)}}
  end

  defp collect(port, timeout_ms, chunks, bytes) do
    receive do
      {^port, {:data, chunk}} when bytes + byte_size(chunk) <= @maximum_output_bytes ->
        collect(port, timeout_ms, [chunk | chunks], bytes + byte_size(chunk))

      {^port, {:data, _chunk}} ->
        Port.close(port)
        {:error, {:publication_git_command_failed, :output_too_large}}

      {^port, {:exit_status, 0}} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {^port, {:exit_status, status}} ->
        output = chunks |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()
        {:error, {:publication_git_command_failed, status, output}}
    after
      timeout_ms ->
        Port.close(port)
        {:error, {:publication_git_command_failed, :timeout}}
    end
  end

  defp environment(directory, extra_env) do
    inherited =
      System.get_env()
      |> Map.keys()
      |> Enum.map(&{String.to_charlist(&1), false})

    passthrough =
      Enum.flat_map(@passthrough, fn name ->
        case System.get_env(name) do
          nil -> []
          value -> [{String.to_charlist(name), String.to_charlist(value)}]
        end
      end)

    fixed = [
      {~c"HOME", String.to_charlist(directory)},
      {~c"GIT_CONFIG_GLOBAL", ~c"/dev/null"},
      {~c"GIT_CONFIG_SYSTEM", ~c"/dev/null"},
      {~c"GIT_CONFIG_NOSYSTEM", ~c"1"},
      {~c"GIT_TERMINAL_PROMPT", ~c"0"},
      {~c"LC_ALL", ~c"C"}
    ]

    extras =
      Enum.map(extra_env, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)

    inherited ++ passthrough ++ fixed ++ extras
  end

  defp absolute_directory?(value),
    do: is_binary(value) and Path.type(value) == :absolute and File.dir?(value)

  defp valid_arguments?(arguments) do
    is_list(arguments) and arguments != [] and
      Enum.all?(arguments, fn value ->
        is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
          byte_size(value) <= 16 * 1_024
      end)
  end

  defp valid_env?(values) do
    is_list(values) and Keyword.keyword?(values) and
      Enum.all?(values, fn {name, value} ->
        is_atom(name) and is_binary(value) and String.valid?(value) and
          :binary.match(value, <<0>>) == :nomatch and byte_size(value) <= 16 * 1_024
      end)
  end
end
