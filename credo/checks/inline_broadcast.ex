defmodule Ryker.Checks.InlineBroadcast do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      House rule: every PubSub publish goes through a named per-event
      function (`broadcast_episode_updated/1`), and a context's `subscribe_*`
      and `broadcast_*` functions sit together in its `# -- PubSub ----`
      section, so its topics and message shapes read in one place (Emisar's
      README).

      The check flags a `Ryker.PubSub` publish (`broadcast/2`,
      `broadcast_to_aliases/2`, ...) inside a function not named
      `broadcast_*`: an inline broadcast at a mutation site. It also flags a
      function that subscribes, unsubscribes or publishes, or is named
      `broadcast_*`, outside its module's `# -- PubSub` section, which runs
      from that header to the next `# --` header.
      """
    ]

  @header ~r/^\s*# -- PubSub\b/
  @next_header ~r/^\s*# -- /

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if relevant?(source_file.filename) do
      ctx = Context.build(source_file, params, __MODULE__)
      section = source_file |> SourceFile.lines() |> section()
      result = Credo.Code.prewalk(source_file, &walk(&1, &2, section), ctx)
      result.issues
    else
      []
    end
  end

  defp relevant?(filename) do
    String.contains?(filename, "lib/ryker/") and
      not String.ends_with?(filename, "lib/ryker/pubsub.ex")
  end

  # The lines the `# -- PubSub` section spans, or nil when the module has none.
  defp section(lines) do
    case Enum.find(lines, &header?(&1, @header)) do
      {start, _line} ->
        later = Enum.drop_while(lines, fn {number, _line} -> number <= start end)

        case Enum.find(later, &header?(&1, @next_header)) do
          {finish, _line} -> {start, finish}
          nil -> {start, :infinity}
        end

      nil ->
        nil
    end
  end

  defp header?({_number, line}, pattern), do: Regex.match?(pattern, line)

  defp walk({def_kind, meta, [head | body]} = ast, ctx, section)
       when def_kind in [:def, :defp] do
    name = def_name(head)
    {publishes, subscriptions} = body |> pubsub_calls() |> Enum.split_with(&publish?/1)
    broadcaster? = String.starts_with?(name, "broadcast_")

    # A publish from any other function is moved into a `broadcast_*` one,
    # which then belongs in the section; the function itself stays put.
    ctx =
      if broadcaster?,
        do: ctx,
        else: Enum.reduce(publishes, ctx, &put_issue(&2, inline(&2, &1)))

    if (broadcaster? or subscriptions != []) and not within?(meta[:line], section),
      do: {ast, put_issue(ctx, outside_section(ctx, meta, name, section))},
      else: {ast, ctx}
  end

  defp walk(ast, ctx, _section), do: {ast, ctx}

  defp def_name({:when, _, [inner | _]}), do: def_name(inner)
  defp def_name({name, _, _}) when is_atom(name), do: Atom.to_string(name)
  defp def_name(_head), do: ""

  # Every call into `Ryker.PubSub` or `Phoenix.PubSub` in `body`.
  defp pubsub_calls(body) do
    {_body, calls} =
      Macro.prewalk(body, [], fn
        {{:., _, [{:__aliases__, meta, [root, :PubSub]}, fun]}, _, args} = node, calls
        when root in [:Ryker, :Phoenix] and is_list(args) ->
          {node, [{fun, meta} | calls]}

        node, calls ->
          {node, calls}
      end)

    Enum.reverse(calls)
  end

  defp publish?({fun, _meta}), do: fun |> Atom.to_string() |> String.contains?("broadcast")

  defp within?(_line, nil), do: false
  defp within?(line, {start, finish}), do: line > start and line < finish

  defp inline(ctx, {fun, meta}) do
    format_issue(
      ctx,
      message:
        "House rule: inline PubSub.broadcast at a mutation site — publish through " <>
          "a named per-event broadcast_* function in the context's PubSub section.",
      trigger: "PubSub.#{fun}",
      line_no: meta[:line],
      column: meta[:column]
    )
  end

  defp outside_section(ctx, meta, name, section) do
    where = if section, do: "outside its module's", else: "in a module with no"

    format_issue(
      ctx,
      message:
        "`#{name}` subscribes or publishes #{where} `# -- PubSub` section: keep a " <>
          "context's subscribe_* and broadcast_* functions together under that header.",
      trigger: name,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
