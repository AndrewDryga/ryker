defmodule Ryker.TestMigrations do
  @moduledoc """
  Every migration as `{version, module}`, for tests that migrate a scratch
  schema with `Ecto.Migrator.run/4`.

  Given the migrations directory, the migrator compiles every file again on
  each call, so a test run printed a "redefining module" warning per
  migration for every migration test after the first (2026-10-04 review).
  Each file is compiled once per run here, only when its module is not
  loaded yet.
  """

  @key {__MODULE__, :migrations}

  @spec all() :: [{pos_integer(), module()}]
  def all,
    do: :persistent_term.get(@key, nil) || :global.trans({__MODULE__, self()}, &load_once/0)

  defp load_once do
    case :persistent_term.get(@key, nil) do
      nil ->
        migrations = load()
        :persistent_term.put(@key, migrations)
        migrations

      migrations ->
        migrations
    end
  end

  @doc "The newest migration version below `version`."
  @spec version_before(pos_integer()) :: pos_integer()
  def version_before(version),
    do: all() |> Enum.map(&elem(&1, 0)) |> Enum.filter(&(&1 < version)) |> Enum.max()

  defp load do
    Path.expand("../../priv/repo/migrations/*.exs", __DIR__)
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(&{version(&1), module(&1)})
  end

  defp version(file), do: file |> Path.basename() |> Integer.parse() |> elem(0)

  defp module(file) do
    [_definition, name] = Regex.run(~r/^defmodule\s+([\w.]+)\s+do/m, File.read!(file))
    module = Module.concat([name])
    unless Code.ensure_loaded?(module), do: Code.compile_file(file)
    module
  end
end
