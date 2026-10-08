defmodule Ryker.Checks.CrossContextDeepAlias do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      House rule (Emisar's): reference ANOTHER context's modules through its
      top-level alias — `alias Ryker.Work` then `Work.Turn`, never
      `alias Ryker.Work.Turn`. It keeps obvious which context a module
      belongs to.

      A file's own context is the second part of the first module it
      defines (`Ryker.ControlPlane.CasesPage` is in ControlPlane). Allowed:
      aliasing the own context's modules directly, any top-level module
      (`alias Ryker.Repo`, `alias Ryker.Work`), and `Ryker.Repo.*` (infra,
      not a context). Applies to `lib/`.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?("/" <> source_file.filename, "/lib/") do
      own = own_context(source_file)
      ctx = Context.build(source_file, params, __MODULE__, %{own_context: own})
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp own_context(source_file) do
    Credo.Code.prewalk(
      source_file,
      fn
        {:defmodule, _, [{:__aliases__, _, [:Ryker, top | _]} | _]} = ast, nil -> {ast, top}
        ast, acc -> {ast, acc}
      end,
      nil
    )
  end

  # alias Ryker.<Ctx>.<Sub> (possibly with :as)
  defp walk({:alias, _, [{:__aliases__, meta, [:Ryker, top, _ | _]} | _]} = ast, ctx),
    do: {ast, flag_if_foreign(ctx, meta, top)}

  # alias Ryker.<Ctx>.{A, B}
  defp walk(
         {:alias, _, [{{:., _, [{:__aliases__, meta, [:Ryker, top | _]}, :{}]}, _, _}]} = ast,
         ctx
       ),
       do: {ast, flag_if_foreign(ctx, meta, top)}

  # alias Ryker.{A, B.C}: a branch two deep into another context
  defp walk(
         {:alias, _, [{{:., _, [{:__aliases__, meta, [:Ryker]}, :{}]}, _, branches}]} = ast,
         ctx
       ) do
    ctx =
      Enum.reduce(branches, ctx, fn
        {:__aliases__, _, [top, _ | _]}, ctx -> flag_if_foreign(ctx, meta, top)
        _branch, ctx -> ctx
      end)

    {ast, ctx}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp flag_if_foreign(ctx, meta, top) do
    if top == :Repo or top == ctx.own_context,
      do: ctx,
      else: put_issue(ctx, issue_for(ctx, meta, "Ryker.#{top}"))
  end

  defp issue_for(ctx, meta, trigger) do
    format_issue(
      ctx,
      message:
        "House rule: cross-context deep alias — alias the owning context " <>
          "(alias #{trigger}) and reference its modules through it.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
