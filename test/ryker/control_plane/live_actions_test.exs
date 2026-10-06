defmodule Ryker.ControlPlane.LiveActionsTest do
  # The current callbacks are one value for the whole node.
  use ExUnit.Case, async: false
  alias Ryker.ControlPlane.Actions

  setup do
    on_exit(fn -> Actions.put_current(Actions.callbacks()) end)
  end

  # The console takes a settings change without a restart (mac-server, 2026-10-01): its actions
  # call whatever callbacks are current, so a live action that dropped or reordered an argument
  # would break that action only on a running installation.
  test "every live action calls the current callback with its own arguments" do
    current =
      Map.new(Actions.callbacks(), fn {name, fun} ->
        {:arity, arity} = Function.info(fun, :arity)
        {name, recorder(name, arity)}
      end)

    :ok = Actions.put_current(current)

    for {name, fun} <- Actions.live() do
      {:arity, arity} = Function.info(fun, :arity)
      arguments = Enum.map(1..arity//1, &{:argument, &1})
      assert apply(fun, arguments) == {name, arguments}
    end
  end

  defp recorder(name, 0), do: fn -> {name, []} end
  defp recorder(name, 1), do: fn a -> {name, [a]} end
  defp recorder(name, 2), do: fn a, b -> {name, [a, b]} end
  defp recorder(name, 3), do: fn a, b, c -> {name, [a, b, c]} end
  defp recorder(name, 4), do: fn a, b, c, d -> {name, [a, b, c, d]} end
  defp recorder(name, 5), do: fn a, b, c, d, e -> {name, [a, b, c, d, e]} end
end
