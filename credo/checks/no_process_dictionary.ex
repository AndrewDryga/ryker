defmodule Ryker.Checks.NoProcessDictionary do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      No process dictionary for ambient request/audit state. `Process.put/2`
      is an ambient channel: whatever a process stashed for one request is
      read by the next thing that runs in it, so who did something can be
      recorded as whoever the process served before.

      Who acts (the console person, the Slack actor) is passed as an explicit
      argument and recorded from it. Thread it; never stash it in the process
      dictionary.

      A genuinely process-local cache or bookkeeping that is NOT request/audit
      state (a page read's memo, a transaction's after-commit queue) gets an
      inline `# credo:disable-for-next-line` with a why-comment.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?("/" <> source_file.filename, "/lib/") do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, [:Process]}, :put]}, _, args} = ast, ctx)
       when is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta) do
    format_issue(
      ctx,
      message:
        "Process.put stashes ambient state — pass who acts as an explicit " <>
          "argument; a process-local cache that is not request state gets a " <>
          "credo:disable-for-next-line with its why.",
      trigger: "Process.put",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
