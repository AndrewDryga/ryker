defmodule Ryker.Checks.UseRykerRole do
  use Credo.Check,
    base_priority: :high,
    category: :design,
    explanations: [
      check: """
      Iron Laws IL-6 and IL-8: a data module takes its role from `use Ryker`,
      as Emisar's take theirs from `use Emisar`. A schema module (one that
      calls `schema "<table>"`) uses `use Ryker, :schema`, which sets the
      UUIDv7 primary key, binary-id foreign keys and microsecond timestamps; a
      Query module (`<schema>/query.ex`) uses `use Ryker, :query`; a Changeset
      module (`<schema>/changeset.ex`) uses `use Ryker, :changeset`.

          # ❌
          use Ecto.Schema
          @primary_key {:id, :binary_id, autogenerate: false}

          # ✅
          use Ryker, :schema

      Flagged: `use Ecto.Schema` in a schema module, `import Ecto.Query` in a
      Query module, `import Ecto.Changeset` in a Changeset module, a Query or
      Changeset module without its `use Ryker`, and a `use Ryker` role in a
      module that does not play it.
      """
    ]

  @doc false
  @impl true
  def run(%SourceFile{} = source_file, params) do
    ctx = Context.build(source_file, params, __MODULE__)
    filename = source_file.filename
    found = Credo.Code.prewalk(source_file, &collect/2, %{roles: [], raw: [], table?: false})

    expected =
      cond do
        String.ends_with?(filename, "/query.ex") -> :query
        String.ends_with?(filename, "/changeset.ex") -> :changeset
        found.table? -> :schema
        true -> nil
      end

    raw_issues(ctx, found.raw, expected) ++
      role_issues(ctx, found.roles, expected) ++ missing_issues(ctx, found.roles, expected)
  end

  defp collect({:use, meta, [{:__aliases__, _, [:Ryker]}, role]} = ast, acc) when is_atom(role),
    do: {ast, %{acc | roles: [{role, meta} | acc.roles]}}

  defp collect({:use, meta, [{:__aliases__, _, [:Ecto, :Schema]} | _]} = ast, acc),
    do: {ast, %{acc | raw: [{:schema, meta, "use Ecto.Schema"} | acc.raw]}}

  defp collect({:import, meta, [{:__aliases__, _, [:Ecto, :Query]} | _]} = ast, acc),
    do: {ast, %{acc | raw: [{:query, meta, "import Ecto.Query"} | acc.raw]}}

  defp collect({:import, meta, [{:__aliases__, _, [:Ecto, :Changeset]} | _]} = ast, acc),
    do: {ast, %{acc | raw: [{:changeset, meta, "import Ecto.Changeset"} | acc.raw]}}

  # `schema "table" do`: a table schema (an embedded value object is not one).
  defp collect({:schema, _, [table | _]} = ast, acc) when is_binary(table),
    do: {ast, %{acc | table?: true}}

  defp collect(ast, acc), do: {ast, acc}

  # The raw Ecto line in a module whose role `use Ryker` gives.
  defp raw_issues(ctx, raw, expected) do
    for {role, meta, trigger} <- raw, role == expected do
      issue_for(ctx, meta, trigger, "use `use Ryker, #{inspect(role)}` instead")
    end
  end

  defp role_issues(ctx, roles, expected) do
    for {role, meta} <- roles, role != expected do
      issue_for(
        ctx,
        meta,
        "use Ryker, #{inspect(role)}",
        "this module is not a #{role} module (#{where(role)})"
      )
    end
  end

  defp missing_issues(_ctx, _roles, nil), do: []

  defp missing_issues(ctx, roles, expected) do
    if Enum.any?(roles, fn {role, _meta} -> role == expected end),
      do: [],
      else: [
        issue_for(
          ctx,
          [line: 1],
          "defmodule",
          "a #{expected} module starts with `use Ryker, #{inspect(expected)}`"
        )
      ]
  end

  defp where(:schema), do: ~s(one that calls `schema "<table>"`)
  defp where(:query), do: "`<schema>/query.ex`"
  defp where(:changeset), do: "`<schema>/changeset.ex`"
  defp where(_role), do: "Ryker has no such role"

  defp issue_for(ctx, meta, trigger, detail) do
    format_issue(
      ctx,
      message: "IL-6/IL-8: a data module takes its role from `use Ryker`: #{detail}.",
      trigger: trigger,
      line_no: meta[:line],
      column: meta[:column]
    )
  end
end
