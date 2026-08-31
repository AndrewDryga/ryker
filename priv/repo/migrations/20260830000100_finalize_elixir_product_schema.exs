defmodule Responder.Repo.Migrations.FinalizeElixirProductSchema do
  use Ecto.Migration

  @schema_root "priv/repo/schema"

  def up do
    run_sql_file("20260830_stage4_base_up.sql")
    run_sql_file("20260830_stage4_new_tables.sql")
  end

  def down do
    run_sql_file("20260830_stage4_new_tables_down.sql")
    run_sql_file("20260830_stage4_base_down.sql")
  end

  defp run_sql_file(name) do
    :responder
    |> Application.app_dir(Path.join(@schema_root, name))
    |> File.read!()
    |> String.replace("public.", quoted_prefix() <> ".")
    |> String.split(~r/;\s*(?:\n|$)/, trim: true)
    |> Enum.each(&execute(String.trim(&1) <> ";"))
  end

  defp quoted_prefix do
    value = prefix() || "public"
    ~s("#{String.replace(value, "\"", "\"\"")}")
  end
end
