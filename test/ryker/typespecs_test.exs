defmodule Ryker.TypespecsTest do
  # A spec or type that names `Module.t()` where the module defines no `t`
  # still compiles: Elixir checks local types, not remote ones, and this
  # build runs no Dialyzer. On 2026-10-07 specs and types named 34 Ryker
  # modules' `t/0` that did not exist, the settings snapshot's among them, so
  # those specs promised a type nothing could check. This resolves every
  # remote type a Ryker spec, type or callback names.
  use ExUnit.Case, async: true

  test "every remote type a Ryker spec, type or callback names exists" do
    modules = for module <- Application.spec(:ryker, :modules), ryker?(module), do: module

    missing =
      for module <- modules,
          {:remote_type, _, [{:atom, _, target}, {:atom, _, name}, arguments]} <-
            remote_types(module),
          ryker?(target),
          not defined?(target, name, length(arguments)),
          uniq: true,
          do: "#{inspect(module)} names #{inspect(target)}.#{name}/#{length(arguments)}"

    assert Enum.sort(missing) == []
  end

  defp ryker?(module), do: String.starts_with?(Atom.to_string(module), "Elixir.Ryker.")

  defp remote_types(module) do
    specs =
      [Code.Typespec.fetch_specs(module), Code.Typespec.fetch_callbacks(module)]
      |> Enum.flat_map(&spec_forms/1)

    Enum.flat_map(specs ++ type_forms(Code.Typespec.fetch_types(module)), &collect/1)
  end

  defp spec_forms({:ok, entries}), do: Enum.flat_map(entries, fn {_name, forms} -> forms end)
  defp spec_forms(:error), do: []

  defp type_forms({:ok, entries}),
    do: Enum.map(entries, fn {_kind, {_name, form, _vars}} -> form end)

  defp type_forms(:error), do: []

  defp collect({:remote_type, _, [_module, _name, arguments]} = remote),
    do: [remote | Enum.flat_map(arguments, &collect/1)]

  defp collect(form) when is_tuple(form), do: form |> Tuple.to_list() |> Enum.flat_map(&collect/1)
  defp collect(forms) when is_list(forms), do: Enum.flat_map(forms, &collect/1)
  defp collect(_leaf), do: []

  defp defined?(module, name, arity),
    do: {name, arity} in exported_types(Code.Typespec.fetch_types(module))

  defp exported_types({:ok, types}) do
    for {kind, {name, _form, vars}} <- types, kind in [:type, :opaque], do: {name, length(vars)}
  end

  defp exported_types(:error), do: []
end
