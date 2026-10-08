defmodule Ryker.Config do
  @moduledoc """
  Ryker's application configuration, read and written in one place: what
  `config/*.exs` sets at boot, and the applied snapshot
  `Ryker.Runtime.Assembly.publish/1` writes each time settings are applied.

  In every environment but `:test` a read is `Application`'s. In `:test` a
  read first consults an override `put_override/2` set for the calling test,
  found on the calling process, then on the root of its `$callers` (a task, a
  LiveView under test) and of its `$ancestors` (a process the test started
  with `start_supervised!/1`). A test configures what it needs without
  touching the process-wide environment every other test reads, and the
  override goes when the test's process does (`Ryker.Checks.NoApplicationPutEnv`).
  The same seam as Emisar's `Emisar.Config`.
  """

  # An override lives in the test process's dictionary, so it dies with that
  # process: no restore, no global mutation. This is the one sanctioned use
  # outside a request's own memo, and it is test-only.
  # credo:disable-for-this-file Ryker.Checks.NoProcessDictionary

  @app :ryker

  @doc """
  Publishes `value` as the applied configuration under `key`, for every
  process to read. Only `Ryker.Runtime.Assembly` applies settings.
  """
  @spec publish(atom(), term()) :: :ok
  # credo:disable-for-next-line Ryker.Checks.NoApplicationPutEnv
  def publish(key, value), do: Application.put_env(@app, key, value, persistent: true)

  @doc "Withdraws the applied configuration under `key`."
  @spec withdraw(atom()) :: :ok
  # credo:disable-for-next-line Ryker.Checks.NoApplicationPutEnv
  def withdraw(key), do: Application.delete_env(@app, key, persistent: true)

  if Mix.env() == :test do
    @doc "The value under `key`: a test's override, else the application's, else `default`."
    @spec get_env(atom(), term()) :: term()
    def get_env(key, default \\ nil) do
      case fetch_override(key) do
        {:ok, value} -> value
        :error -> Application.get_env(@app, key, default)
      end
    end

    @doc "The value under `key`, a test's override first."
    @spec fetch_env(atom()) :: {:ok, term()} | :error
    def fetch_env(key) do
      with :error <- fetch_override(key), do: Application.fetch_env(@app, key)
    end

    @doc "The value under `key`, a test's override first; raises when there is none."
    @spec fetch_env!(atom()) :: term()
    def fetch_env!(key) do
      case fetch_override(key) do
        {:ok, value} -> value
        :error -> Application.fetch_env!(@app, key)
      end
    end

    @doc "Every key and value, with a test's overrides in place of the application's."
    @spec get_all_env() :: keyword()
    def get_all_env do
      overrides =
        owners()
        |> Enum.reverse()
        |> Enum.reduce(%{}, fn owner, overrides -> Map.merge(overrides, overrides_of(owner)) end)

      Keyword.merge(Application.get_all_env(@app), Map.to_list(overrides))
    end

    @doc """
    Overrides `key` with `value` for the calling test and the processes it
    reaches through `$callers` and `$ancestors`. A `nil` override still reads
    as `nil`. Test-only.
    """
    @spec put_override(atom(), term()) :: :ok
    def put_override(key, value) do
      Process.put({__MODULE__, key}, value)
      :ok
    end

    defp fetch_override(key) do
      Enum.find_value(owners(), :error, fn owner ->
        case Map.fetch(overrides_of(owner), key) do
          {:ok, value} -> {:ok, value}
          :error -> nil
        end
      end)
    end

    # Who may hold the override: the calling process, then the root of its
    # callers, then the root of its ancestors.
    defp owners, do: [self(), stack_root(:"$callers"), stack_root(:"$ancestors")]

    defp overrides_of(owner),
      do: for({{__MODULE__, key}, value} <- dictionary(owner), into: %{}, do: {key, value})

    defp dictionary(owner) when owner == self(), do: Process.get()

    defp dictionary(owner) when is_pid(owner) do
      case Process.info(owner, :dictionary) do
        {:dictionary, entries} -> entries
        nil -> []
      end
    end

    defp dictionary(owner) when is_atom(owner) and not is_nil(owner),
      do: owner |> Process.whereis() |> dictionary()

    defp dictionary(_none), do: []

    defp stack_root(stack) do
      case Process.get(stack) do
        [_ | _] = processes -> List.last(processes)
        _none -> nil
      end
    end
  else
    @doc "The value under `key`, else `default`."
    @spec get_env(atom(), term()) :: term()
    def get_env(key, default \\ nil), do: Application.get_env(@app, key, default)

    @doc "The value under `key`."
    @spec fetch_env(atom()) :: {:ok, term()} | :error
    def fetch_env(key), do: Application.fetch_env(@app, key)

    @doc "The value under `key`; raises when there is none."
    @spec fetch_env!(atom()) :: term()
    def fetch_env!(key), do: Application.fetch_env!(@app, key)

    @doc "Every key and value."
    @spec get_all_env() :: keyword()
    def get_all_env, do: Application.get_all_env(@app)
  end
end
