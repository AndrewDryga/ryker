defmodule Ryker.Checks.PreferCaptureClosure do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      House rule: a closure whose body is a single call uses capture syntax.

      `fn x -> f(x) end` is `&f/1`; with extra args it's `&f(&1, extra)`;
      a bare field read is `& &1.field`. `fn` earns its keep only for
      multi-step bodies, pattern-matching heads, multi-clause closures,
      zero-arity closures over scope values, closures nested inside an
      outer capture (pruned here — capture-in-capture won't compile),
      arguments used more than once, an argument read only inside
      another closure (`fn x -> Enum.map(ys, fn y -> {x, y} end) end`),
      whose `&1` would hide in that inner `fn`, an argument pinned into a
      query (`^&1.id` reads worse than `^item.id`), and a body written over
      several lines, where `&1` would sit somewhere inside a block.
      """
    ]

  # Not convertible bodies: control flow, blocks, pipes — and the literal
  # constructors (binaries/tuples/maps/structs), which are not calls.
  @special_forms [
    :fn,
    :if,
    :unless,
    :case,
    :cond,
    :with,
    :for,
    :receive,
    :try,
    :quote,
    :=,
    :|>,
    :__block__,
    :&,
    :<<>>,
    :{},
    :%{},
    :%,
    :|,
    :"::"
  ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  # A capture can't nest another capture — don't look inside `&`.
  defp walk({:&, _, _}, ctx), do: {nil, ctx}

  defp walk({:fn, meta, [{:->, _, [[{var, _, var_ctx}], body]}]} = ast, ctx)
       when is_atom(var) and is_atom(var_ctx) do
    if not String.starts_with?(Atom.to_string(var), "_") and one_line?(meta) and
         not pinned?(body, var) and convertible?(body, var) do
      {ast, put_issue(ctx, issue_for(ctx, meta, "fn #{var} ->"))}
    else
      {ast, ctx}
    end
  end

  defp walk(ast, ctx), do: {ast, ctx}

  # fn x -> x.field end  →  & &1.field
  defp convertible?({{:., _, [{var, _, _}, field]}, _, []}, var) when is_atom(field), do: true

  # fn x -> Mod.fun(..x..) end  →  &Mod.fun(..&1..)
  defp convertible?({{:., _, [_mod, fun]}, _, args} = body, var)
       when is_atom(fun) and is_list(args),
       do: used_exactly_once?(body, var) and not contains?(body, [:&, :fn])

  # fn x -> fun(..x..) end  →  &fun(..&1..)
  defp convertible?({fun, _, args} = body, var)
       when is_atom(fun) and is_list(args) and fun not in @special_forms,
       do: used_exactly_once?(body, var) and not contains?(body, [:&, :fn])

  defp convertible?(_, _), do: false

  # A capture inside the body blocks conversion: the outer closure becoming
  # a capture would nest captures, which won't compile. So does a closure
  # inside it: `&1` read inside an inner `fn` compiles, and nobody sees it.
  defp contains?(body, forms) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {form, _, _} = node, acc -> {node, acc or form in forms}
        node, acc -> {node, acc}
      end)

    found
  end

  # The body's own lines: between `fn x ->` and `end` when the closure is
  # written over several lines, the one line otherwise.
  defp one_line?(meta) do
    case {meta[:line], get_in(meta, [:closing, :line])} do
      {line, line} -> true
      {line, closing} when is_integer(line) and is_integer(closing) -> closing - line - 1 == 1
      _unknown -> false
    end
  end

  defp pinned?(body, var) do
    {_, found} =
      Macro.prewalk(body, false, fn
        {:^, _, [pinned]} = node, found -> {node, found or uses(pinned, var) > 0}
        node, found -> {node, found}
      end)

    found
  end

  defp used_exactly_once?(body, var), do: uses(body, var) == 1

  defp uses(body, var) do
    {_, count} =
      Macro.prewalk(body, 0, fn
        {^var, _, ctx} = node, count when is_atom(ctx) -> {node, count + 1}
        node, count -> {node, count}
      end)

    count
  end

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: single-call forwarding closure — use capture syntax " <>
          "(&fun/1, &fun(&1, extra), or & &1.field).",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
