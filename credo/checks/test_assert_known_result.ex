defmodule Ryker.Checks.TestAssertKnownResult do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      House rule (Emisar's test taste): a fully known result is asserted with
      `==`, not matched with `=`.

          # ❌
          assert {:error, :not_found} = Episodes.fetch(id)

          # ✅
          assert Episodes.fetch(id) == {:error, :not_found}

      `==` states the value and fails with a left/right diff; `=` is for
      binding a value or matching part of one. Flagged in tests: an
      `assert pattern = expr` whose pattern binds nothing and holds no map
      (a map pattern matches part of a map) or float (`==` would take an
      integer for it).
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.ends_with?(source_file.filename, "_test.exs") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({:assert, meta, [{:=, _, [pattern, _expr]}]} = ast, ctx) do
    if known?(pattern),
      do: {ast, put_issue(ctx, issue_for(ctx, meta))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp known?({:{}, _, elements}), do: Enum.all?(elements, &known?/1)
  defp known?({first, second}), do: known?(first) and known?(second)
  defp known?(list) when is_list(list), do: Enum.all?(list, &known?/1)
  defp known?({:-, _, [number]}) when is_integer(number), do: true
  defp known?({_, _, _}), do: false
  defp known?(value), do: is_atom(value) or is_integer(value) or is_binary(value)

  defp issue_for(ctx, meta) do
    format_issue(ctx,
      message: "A fully known result is asserted with `==`: `assert expr == value`.",
      line_no: meta[:line]
    )
  end
end
