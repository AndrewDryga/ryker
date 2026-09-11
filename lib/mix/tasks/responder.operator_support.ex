defmodule Mix.Tasks.Responder.OperatorSupport do
  @moduledoc false

  alias Responder.{Bootstrap, Repo, Settings}
  alias Responder.Runtime.Assembly

  def parse(arguments, switches, positional_count) do
    {options, positional, invalid} = OptionParser.parse(arguments, strict: switches)

    valid =
      invalid == [] and unique_switches?(arguments, switches) and
        valid_positional_count?(positional, positional_count) and
        Keyword.keyword?(options) and
        Enum.uniq(Keyword.keys(options)) == Keyword.keys(options)

    if valid, do: {:ok, options, positional}, else: {:error, :invalid_arguments}
  end

  @doc """
  The same durable settings the release applies, assembled for this Mix process.

  Operator commands read the installation's saved settings; there is no
  configuration path to point them somewhere else, and an uninitialized or
  unreadable database is reported rather than replaced with defaults.
  """
  def configuration do
    with {:ok, settings} <- Settings.fetch(),
         {:ok, configuration} <- Assembly.build(Bootstrap.load!(), settings) do
      Assembly.publish(configuration)
      {:ok, configuration}
    end
  rescue
    error in [ArgumentError, DBConnection.ConnectionError, Postgrex.Error] ->
      {:error, {:settings_unavailable, error.__struct__}}
  end

  def with_repo(operation) when is_function(operation, 0) do
    repo = Mix.Ecto.ensure_repo(Repo, [])

    case Ecto.Migrator.with_repo(repo, fn _repo -> operation.() end, mode: :temporary) do
      {:ok, result, _started_apps} -> result
      {:error, reason} -> {:error, {:operator_repository_unavailable, reason}}
    end
  end

  @doc "Runs an operator command against the applied configuration."
  def with_configuration(operation) when is_function(operation, 1) do
    with_repo(fn ->
      case configuration() do
        {:ok, configuration} -> operation.(configuration)
        {:error, _reason} = error -> error
      end
    end)
  end

  def print(value), do: Mix.shell().info(Jason.encode!(value))

  @doc """
  Resolves a mutating operator identity against the saved operator membership.

  Membership is a durable setting, so a disconnected Slack integration does not
  silently revoke it, and a connected one does not grant it.
  """
  def authorized_actor(options) when is_list(options) do
    operator = Keyword.get(options, :operator)

    with {:ok, settings} <- Settings.fetch() do
      if is_binary(operator) and operator in settings.slack.operators,
        do: {:ok, "slack:user:#{operator}"},
        else: {:error, :configured_slack_operator_required}
    end
  end

  def authorized_actor(_options), do: {:error, :configured_slack_operator_required}

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
end
