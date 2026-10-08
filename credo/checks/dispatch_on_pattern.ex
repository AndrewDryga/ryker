defmodule Ryker.Checks.DispatchOnPattern do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      House rule (Emisar's `elixir-dispatch-on-pattern`): a function whose
      body is one `if` or `case` on a pattern-matchable property of its own
      argument is clause heads instead.

          # ❌
          defp after_wait(followup, now) do
            if followup.pr_state == :open, do: now, else: @far_future
          end

          # ✅
          defp after_wait(%{pr_state: :open}, now), do: now
          defp after_wait(_followup, _now), do: @far_future

      Flagged, for a named function's clause or a closure: a whole body that
      is an `if` or `unless` with an `else`, testing an argument or one of
      its fields for nil (`is_nil/1`), for a literal (`==`, `!=`, `===`,
      `!==` against an atom, integer or string), or for truthiness; and a
      whole body that is a `case` on an argument with two or more clauses.
      `if` stays for a computed condition, and `case` for anything that is
      not the argument itself. A closure testing its argument's field for
      truthiness alone is `NoIfOnArgField`'s.
      """
    ]

  @comparisons [:==, :!=, :===, :!==]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  defp walk({kind, meta, [head, [do: body]]} = ast, ctx) when kind in [:def, :defp] do
    {ast, check(ctx, meta, arguments(head), body, false)}
  end

  defp walk({:fn, meta, [{:->, _, [arguments, body]}]} = ast, ctx) do
    arguments = Enum.map(arguments, &unguarded/1)
    {ast, check(ctx, meta, names(arguments), body, length(arguments) == 1)}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp check(ctx, meta, names, body, single_argument_closure?) do
    case dispatch(body, names) do
      {:truthiness_of_field, _trigger} when single_argument_closure? -> ctx
      {_kind, trigger} -> put_issue(ctx, issue_for(ctx, meta, trigger))
      nil -> ctx
    end
  end

  defp arguments({:when, _, [head | _guards]}), do: arguments(head)

  defp arguments({name, _, arguments}) when is_atom(name) and is_list(arguments),
    do: names(arguments)

  defp arguments(_head), do: []

  defp unguarded({:when, _, [argument | _guards]}), do: argument
  defp unguarded(argument), do: argument

  defp names(arguments) do
    Enum.flat_map(arguments, fn
      {:\\, _, [argument, _default]} -> names([argument])
      {:=, _, [left, right]} -> names([left]) ++ names([right])
      {name, _, context} when is_atom(name) and is_atom(context) -> [name]
      _pattern -> []
    end)
  end

  defp dispatch({op, _, [condition, [do: _then, else: _else]]}, names)
       when op in [:if, :unless] do
    case condition(condition, names) do
      nil -> nil
      kind -> {kind, "#{op} " <> Macro.to_string(condition)}
    end
  end

  defp dispatch({:case, _, [{name, _, context}, [do: clauses]]}, names)
       when is_atom(name) and is_atom(context) and length(clauses) >= 2 do
    if name in names, do: {:case, "case #{name}"}
  end

  defp dispatch(_body, _names), do: nil

  defp condition({:is_nil, _, [subject]}, names), do: subject(subject, names) && :nil_check

  defp condition({op, _, [subject]}, names) when op in [:not, :!],
    do: subject(subject, names) && :truthiness

  defp condition({op, _, [left, right]}, names) when op in @comparisons do
    if (subject(left, names) && literal?(right)) || (subject(right, names) && literal?(left)),
      do: :literal
  end

  defp condition(subject, names) do
    case subject(subject, names) do
      :field -> :truthiness_of_field
      :argument -> :truthiness
      nil -> nil
    end
  end

  # An argument, or a field of one read without parentheses (`argument.field`).
  defp subject({name, _, context}, names) when is_atom(name) and is_atom(context),
    do: if(name in names, do: :argument)

  defp subject({{:., _, [{name, _, context}, field]}, meta, []}, names)
       when is_atom(name) and is_atom(context) and is_atom(field) do
    if name in names and Keyword.get(meta, :no_parens, false), do: :field
  end

  defp subject(_expression, _names), do: nil

  defp literal?(value), do: is_atom(value) or is_integer(value) or is_binary(value)

  defp issue_for(ctx, meta, trigger) do
    format_issue(ctx,
      message:
        "House rule: a body that only dispatches on its argument is clause heads (dispatch on a pattern).",
      trigger: trigger,
      line_no: meta[:line]
    )
  end
end
