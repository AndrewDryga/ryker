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

  # The migration module, loaded once: Ecto's migrator may already have
  # compiled it, and compiling it again would redefine it.
  defp module(file) do
    [_definition, name] = Regex.run(~r/^defmodule\s+([\w.]+)\s+do/m, File.read!(file))

    case loaded(name) do
      nil -> file |> Code.compile_file() |> Enum.find_value(fn {module, _binary} -> module end)
      module -> module
    end
  end

  defp loaded(name) do
    module = Module.safe_concat([name])
    if Code.ensure_loaded?(module), do: module
  rescue
    ArgumentError -> nil
  end
end
