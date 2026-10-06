defmodule Ryker.Checks.AcronymModuleCase do
  use Credo.Check,
    base_priority: :normal,
    category: :readability,
    explanations: [
      check: """
      House rule: an acronym is all-caps in a module name — `Ryker.GitHub.AppJWT`,
      `Ryker.ControlPlane.HTML`, `Ryker.Delivery.JSONClient`, not `Jwt`/`Html`/`Json`.
      CamelCase capitalizes each word; an initialism is one all-caps unit.

      (snake_case identifiers stay lowercase — `json_body`, the `/v1/mcp`
      path — this is module/alias segments only.)
      """
    ]

  @miscased %{
    Acp: "ACP",
    Api: "API",
    Csrf: "CSRF",
    Html: "HTML",
    Http: "HTTP",
    Json: "JSON",
    Jwt: "JWT",
    Mcp: "MCP",
    Pki: "PKI",
    Sql: "SQL",
    Ssh: "SSH",
    Tls: "TLS",
    Url: "URL",
    Uuid: "UUID"
  }

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    result = Credo.Code.prewalk(source_file, &walk/2, ctx)
    result.issues
  end

  defp walk({:__aliases__, meta, parts} = ast, ctx) when is_list(parts) do
    bad = Enum.filter(parts, &Map.has_key?(@miscased, &1))
    {ast, Enum.reduce(bad, ctx, fn part, acc -> put_issue(acc, issue_for(acc, meta, part)) end)}
  end

  defp walk(ast, ctx), do: {ast, ctx}

  defp issue_for(ctx, meta, part) do
    format_issue(
      ctx,
      message:
        "Acronym `#{part}` must be all-caps in a module name — write `#{@miscased[part]}`.",
      trigger: "#{part}",
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
