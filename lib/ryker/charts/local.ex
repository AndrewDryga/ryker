defmodule Ryker.Charts.Local do
  @moduledoc "Runs the pinned renderer with bounded input, output and execution time."
  alias Ryker.Artifacts
  alias Ryker.ChildEnvironment
  alias Ryker.ChildProcess

  @maximum_bytes 8 * 1_024 * 1_024

  @spec render(map(), keyword()) :: {:ok, binary()} | {:error, term()}
  def render(spec, options) do
    python =
      Keyword.get(
        options,
        :python,
        System.get_env("RYKER_CHART_PYTHON", "/opt/ryker-charts/bin/python3")
      )

    renderer =
      Keyword.get(options, :renderer, Application.app_dir(:ryker, "priv/charts/render.py"))

    input = Jason.encode!(spec)

    cond do
      byte_size(input) > 256 * 1_024 ->
        {:error, {:invalid_chart, "/data", "encoded chart exceeds 256 KiB"}}

      not File.regular?(python) ->
        {:error, :chart_renderer_unavailable}

      true ->
        render_one(python, renderer, input, Keyword.get(options, :timeout_ms, 15_000))
    end
  end

  # Native runtimes consume memory before producing bytes. One process per
  # controller bounds that cost even when a model issues parallel tool calls.
  defp render_one(python, renderer, input, timeout) do
    lock = {__MODULE__, self()}

    if :global.set_lock(lock, [node()], 0) do
      try do
        run(python, renderer, input, timeout)
      after
        :global.del_lock(lock, [node()])
      end
    else
      {:error, :chart_renderer_busy}
    end
  end

  defp run(python, renderer, input, timeout) do
    port =
      Port.open({:spawn_executable, python}, [
        :binary,
        :exit_status,
        :hide,
        args: [renderer],
        env: ChildEnvironment.port()
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)

    try do
      true = Port.command(port, input <> "\n")
      await(port, System.monotonic_time(:millisecond) + timeout, [], 0)
    after
      # Closing a port alone does not stop a renderer still computing.
      if Port.info(port) != nil, do: ChildProcess.signal(os_pid, "KILL")
      ChildProcess.close(port)
    end
  rescue
    _error in [ArgumentError, ErlangError] -> {:error, :chart_render_failed}
  end

  defp await(port, deadline, chunks, size) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, chunk}} when size + byte_size(chunk) <= @maximum_bytes ->
        await(port, deadline, [chunk | chunks], size + byte_size(chunk))

      {^port, {:data, _chunk}} ->
        {:error, :chart_render_failed}

      {^port, {:exit_status, 0}} ->
        bytes = chunks |> Enum.reverse() |> IO.iodata_to_binary()

        if Artifacts.Outputs.image_matches?("image/png", bytes),
          do: {:ok, bytes},
          else: {:error, :chart_render_failed}

      {^port, {:exit_status, _status}} ->
        {:error, :chart_render_failed}
    after
      remaining -> {:error, :chart_render_timeout}
    end
  end
end
