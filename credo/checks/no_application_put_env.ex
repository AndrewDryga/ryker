defmodule Ryker.Checks.NoApplicationPutEnv do
  use Credo.Check,
    base_priority: :high,
    category: :warning,
    explanations: [
      check: """
      No `Application.put_env` / `delete_env` / `put_all_env` in lib, evals or
      test. The application environment is one table for the whole VM, so a
      test that writes it races every `async: true` test reading the same key,
      and a restore in `on_exit` runs after the next test may already have read
      the wrong value.

      Configuration goes through `Ryker.Config`. Code reads with
      `Ryker.Config.get_env/2` / `fetch_env!/1`; a test overrides with
      `Ryker.Config.put_override/2`, which holds for the calling test and the
      processes it reaches through `$callers` and `$ancestors`, and goes with
      the test. `Ryker.Config.publish/2` and `withdraw/1` are the one writer, for
      the settings `Ryker.Runtime.Assembly` applies. A library that reads its
      own application environment gets a test double, not a global swap.
      """
    ]

  @forbidden [:put_env, :delete_env, :put_all_env]
  @scopes ["/lib/", "/evals/", "/test/"]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    if String.contains?("/" <> source_file.filename, @scopes) do
      ctx = Context.build(source_file, params, __MODULE__)
      result = Credo.Code.prewalk(source_file, &walk/2, ctx)
      result.issues
    else
      []
    end
  end

  defp walk({{:., _, [{:__aliases__, meta, [:Application]}, fun]}, _, args} = ast, ctx)
       when fun in @forbidden and is_list(args) do
    {ast, put_issue(ctx, issue_for(ctx, meta, fun))}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, fun) do
    format_issue(
      ctx,
      message:
        "Application.#{fun} changes configuration for every process at once. " <>
          "Override it for one test with Ryker.Config.put_override/2 and read " <>
          "it through Ryker.Config.get_env/2 or fetch_env!/1.",
      trigger: "Application.#{fun}",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
