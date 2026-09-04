defmodule Mix.Tasks.Responder.OperatorSupport do
  @moduledoc false

  alias Responder.Repo
  alias Responder.RuntimeConfiguration

  def parse(arguments, switches, positional_count) do
    {options, positional, invalid} = OptionParser.parse(arguments, strict: switches)

    valid =
      invalid == [] and unique_switches?(arguments, switches) and
        valid_positional_count?(positional, positional_count) and
        Keyword.keyword?(options) and
        Enum.uniq(Keyword.keys(options)) == Keyword.keys(options)

    if valid, do: {:ok, options, positional}, else: {:error, :invalid_arguments}
  end

  def configuration(options, required \\ false) do
    case Keyword.get(options, :config) do
      nil when not required -> {:ok, nil}
      path when is_binary(path) and path != "" -> load_configuration(path)
      _invalid -> {:error, :configuration_path_required}
    end
  end

  def with_repo(operation) when is_function(operation, 0) do
    repo = Mix.Ecto.ensure_repo(Repo, [])

    case Ecto.Migrator.with_repo(repo, fn _repo -> operation.() end, mode: :temporary) do
      {:ok, result, _started_apps} -> result
      {:error, reason} -> {:error, {:operator_repository_unavailable, reason}}
    end
  end

  def print(value), do: Mix.shell().info(Jason.encode!(value))

  def install_configuration(nil), do: :ok

  def install_configuration(configuration) when is_map(configuration) do
    Enum.each(configuration, fn {key, value} ->
      Application.put_env(:responder, key, value, persistent: true)
    end)

    :ok
  end

  def authorized_actor(configuration, options) when is_map(configuration) and is_list(options) do
    operator = Keyword.get(options, :operator)
    operators = get_in(configuration, [:slack, :operators])

    if is_binary(operator) and is_list(operators) and operator in operators do
      {:ok, "slack:user:#{operator}"}
    else
      {:error, :configured_slack_operator_required}
    end
  end

  def authorized_actor(_configuration, _options),
    do: {:error, :configured_slack_operator_required}

  def required_option(options, key) when is_list(options) and is_atom(key) do
    case Keyword.fetch(options, key) do
      {:ok, value} when is_binary(value) and value != "" -> {:ok, value}
      _missing_or_invalid -> {:error, {key, :required}}
    end
  end

  def fail(operation, reason),
    do: Mix.raise("#{operation} failed: #{inspect(reason)}")

  defp valid_positional_count?(positional, count) when is_integer(count),
    do: length(positional) == count

  defp valid_positional_count?(positional, counts) when is_list(counts),
    do: length(positional) in counts

  defp unique_switches?(arguments, switches) do
    Enum.all?(Keyword.keys(switches), fn key ->
      switch = "--" <> (key |> Atom.to_string() |> String.replace("_", "-"))

      Enum.count(arguments, fn argument ->
        argument == switch or String.starts_with?(argument, switch <> "=")
      end) <= 1
    end)
  end

  defp load_configuration(path) do
    if Path.type(path) == :absolute do
      {:ok, RuntimeConfiguration.load!(path)}
    else
      {:error, :configuration_path_must_be_absolute}
    end
  rescue
    error -> {:error, {:configuration_invalid, Exception.message(error)}}
  end
end
