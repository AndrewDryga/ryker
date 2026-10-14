defmodule Ryker.TestSupport.FileTimes do
  @moduledoc """
  An ExUnit formatter that writes how long each test file took, in whole
  milliseconds from its first test module starting to its last finishing, as
  `<milliseconds> <path>` lines to the file `RYKER_TEST_TIMES` names.
  `scripts/elixir-test.sh` deals the serial files across partitions by these
  times (`make serial-times`), so the partitions end together.
  """
  use GenServer

  @impl GenServer
  def init(_options), do: {:ok, %{started: %{}, times: %{}}}

  @impl GenServer
  def handle_cast({:module_started, %ExUnit.TestModule{file: file}}, state) do
    {:noreply, put_in(state.started[file], System.monotonic_time(:millisecond))}
  end

  def handle_cast({:module_finished, %ExUnit.TestModule{file: file}}, state) do
    elapsed = System.monotonic_time(:millisecond) - Map.get(state.started, file)

    {:noreply,
     update_in(state.times, &Map.update(&1, file, elapsed, fn sum -> sum + elapsed end))}
  end

  def handle_cast({:suite_finished, _times}, state) do
    root = File.cwd!()

    lines =
      for {file, milliseconds} <- Enum.sort(state.times),
          do: "#{milliseconds} #{Path.relative_to(file, root)}\n"

    File.write!(System.fetch_env!("RYKER_TEST_TIMES"), lines)
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}
end
