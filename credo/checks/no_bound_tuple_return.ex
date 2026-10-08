defmodule Ryker.Checks.NoBoundTupleReturn do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      House rule (Emisar's): never bind an `{:ok, _}` or `{:error, _}` tuple
      just to return it. The binding hides what the clause returns; restate
      the tuple instead.

          # ❌
          {:error, :lease_lost} = error -> error
          {:error, _reason} = error -> {:halt, error}

          # ✅
          {:error, :lease_lost} -> {:error, :lease_lost}
          {:error, reason} -> {:halt, {:error, reason}}

      Flagged: a clause whose head binds such a tuple to a name and whose
      body is that name alone, or that name as an element of a tuple it
      returns. A tuple passed on to a function keeps its binding.
      """
    ]

  @tags [:ok, :error]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  defp walk({:->, meta, [[head], body]} = ast, ctx) do
    case bound_tuple(head) do
      {:ok, name} ->
        {ast, if(returns?(body, name), do: put_issue(ctx, issue(ctx, meta)), else: ctx)}

      :error ->
        {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp bound_tuple({:when, _, [pattern, _guard]}), do: bound_tuple(pattern)

  defp bound_tuple({:=, _, [{tag, _value}, {name, _, context}]})
       when tag in @tags and is_atom(name) and is_atom(context),
       do: {:ok, name}

  defp bound_tuple({:=, _, [{name, _, context}, {tag, _value}]})
       when tag in @tags and is_atom(name) and is_atom(context),
       do: {:ok, name}

  defp bound_tuple(_head), do: :error

  defp returns?({name, _, context}, name) when is_atom(context), do: true

  # A body that ends in the name, using it nowhere before.
  defp returns?({:__block__, _, [_ | _] = expressions}, name) do
    {before, [last]} = Enum.split(expressions, -1)
    returns?(last, name) and not Enum.any?(before, &uses?(&1, name))
  end

  defp returns?({:{}, _, elements}, name), do: Enum.any?(elements, &returns?(&1, name))

  defp returns?({first, second}, name),
    do: Enum.any?([first, second], &match?({^name, _, context} when is_atom(context), &1))

  defp returns?(_body, _name), do: false

  defp uses?(ast, name) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {^name, _, context} = node, _found when is_atom(context) -> {node, true}
        node, found -> {node, found}
      end)

    found
  end

  defp issue(ctx, meta) do
    format_issue(ctx,
      message:
        "A tuple bound only to be returned: restate it (`{:error, reason} -> {:error, reason}`).",
      line_no: meta[:line]
    )
  end
end
