defmodule Ryker.Repo.Migrations.Baseline do
  use Ecto.Migration

  # The whole schema in one step. The 116 migrations that built it until
  # 2026-09-26 were squashed into priv/repo/schema/baseline.sql (codebase wave
  # 5); an installation migrated through them records this version instead of
  # running it (docs/operations.md, "The schema baseline").
  #
  # There is nothing before the baseline to roll back to: going back means
  # restoring a backup.
  @baseline "priv/repo/schema/baseline.sql"

  def up do
    # pg_dump orders functions before the tables a function body may name.
    execute("SET LOCAL check_function_bodies = false")

    :ryker
    |> Application.app_dir(@baseline)
    |> File.read!()
    |> String.replace(~r/"public"\.|\bpublic\./, quoted_prefix() <> ".")
    |> statements()
    |> Enum.each(&execute/1)
  end

  def down do
    raise "the baseline is where every Ryker schema starts; restore a backup to go back"
  end

  # A statement ends with a semicolon at the end of a line, except inside a
  # dollar-quoted function body.
  defp statements(sql) do
    {done, rest, _quoted} =
      sql
      |> String.split("\n")
      |> Enum.reject(&String.starts_with?(&1, "--"))
      |> Enum.reduce({[], [], false}, fn line, {done, current, quoted} ->
        quoted = if rem(dollar_quotes(line), 2) == 1, do: not quoted, else: quoted
        current = [line | current]

        if not quoted and String.ends_with?(String.trim_trailing(line), ";") do
          {[current |> Enum.reverse() |> Enum.join("\n") |> String.trim() | done], [], quoted}
        else
          {done, current, quoted}
        end
      end)

    if rest |> Enum.join() |> String.trim() != "",
      do: raise("the baseline ends inside a statement")

    Enum.reverse(done)
  end

  defp dollar_quotes(line), do: length(String.split(line, "$$")) - 1

  defp quoted_prefix do
    value = prefix() || "public"
    ~s("#{String.replace(value, "\"", "\"\"")}")
  end
end
