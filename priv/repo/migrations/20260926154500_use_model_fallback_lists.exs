defmodule Ryker.Repo.Migrations.UseModelFallbackLists do
  use Ecto.Migration

  # Settings › Models (Andrew, 2026-09-26): each kind of work keeps an ordered
  # list of models instead of one, the first used and each later one a
  # fallback Coop moves to when the one above hits a usage limit or its
  # account's sign-in fails. A model may be a Claude one as well as Codex, and
  # names the account it runs on; `model_accounts` lists the accounts the
  # worker has signed in, as `provider@name`, since Ryker cannot see them.
  #
  # Every saved model becomes the only one in its list, and the accounts those
  # models already run on become the list of accounts, so nothing the worker
  # runs today changes.

  @kinds %{
    "routing" => "codex:gpt-5.6-sol/medium@default",
    "conversation" => "codex:gpt-5.6-terra/medium@default",
    "standard" => "codex:gpt-5.6-sol/medium@default",
    "deep" => "codex:gpt-5.6-sol/xhigh@default",
    "contributor" => "codex:gpt-5.6-sol/medium@default",
    "schedule" => "codex:gpt-5.6-sol/medium@default",
    "incident" => "codex:gpt-5.6-sol/medium@default",
    "learning" => "codex:gpt-5.6-sol/medium@default"
  }
  @target "(codex|claude):[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}"
  @account "(codex|claude)@[a-z0-9][a-z0-9_-]{0,63}"
  @codex_target "^codex:[a-z0-9][a-z0-9._-]{0,63}/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}$"

  def up do
    alter table(:work_settings) do
      add(:model_accounts, {:array, :text},
        null: false,
        default: fragment("ARRAY['codex@default']::text[]")
      )

      for kind <- Map.keys(@kinds), do: add(:"#{kind}_models", {:array, :text})
    end

    execute("""
    UPDATE #{qualified("work_settings")} SET
      #{Enum.map_join(Map.keys(@kinds), ",\n  ", &"#{&1}_models = ARRAY[#{&1}_model]")},
      model_accounts = ARRAY(
        SELECT DISTINCT split_part(target, ':', 1) || '@' || split_part(target, '@', 2)
        FROM unnest(ARRAY[#{Enum.map_join(Map.keys(@kinds), ", ", &"#{&1}_model")}]) AS target
        ORDER BY 1
      )
    """)

    for {kind, default} <- @kinds do
      drop(constraint(:work_settings, :"work_settings_#{kind}_model_valid"))

      alter table(:work_settings) do
        modify(:"#{kind}_models", {:array, :text},
          null: false,
          default: fragment("ARRAY['#{default}']::text[]")
        )

        remove(:"#{kind}_model")
      end

      create(
        constraint(:work_settings, :"work_settings_#{kind}_models_valid",
          check: list_check("#{kind}_models", @target, 4)
        )
      )
    end

    create(
      constraint(:work_settings, :work_settings_model_accounts_valid,
        check: list_check("model_accounts", @account, 16)
      )
    )
  end

  # The previous release keeps one Codex model per kind of work, the first of
  # each list. A fallback, or a Claude model first, has nowhere to go there, so
  # rolling back waits until they are removed rather than dropping a model
  # someone chose. The accounts list goes: that release has no use for it, and
  # this migration builds it again from the saved models.
  def down do
    lists = Enum.map(Map.keys(@kinds), &"#{&1}_models")

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("work_settings")}
        WHERE #{Enum.map_join(lists, "\n    OR ", &"cardinality(#{&1}) <> 1 OR #{&1}[1] !~ '#{@codex_target}'")}
      ) THEN
        RAISE EXCEPTION 'Settings › Models has a fallback or a Claude model; keep one Codex model for each kind of work there before rolling back';
      END IF;
    END
    $$
    """)

    alter table(:work_settings) do
      for kind <- Map.keys(@kinds), do: add(:"#{kind}_model", :text)
    end

    execute("""
    UPDATE #{qualified("work_settings")} SET
      #{Enum.map_join(Map.keys(@kinds), ",\n  ", &"#{&1}_model = #{&1}_models[1]")}
    """)

    for {kind, default} <- @kinds do
      drop(constraint(:work_settings, :"work_settings_#{kind}_models_valid"))

      alter table(:work_settings) do
        modify(:"#{kind}_model", :text, null: false, default: default)
        remove(:"#{kind}_models")
      end

      create(
        constraint(:work_settings, :"work_settings_#{kind}_model_valid",
          check: "#{kind}_model ~ '#{@codex_target}'"
        )
      )
    end

    drop(constraint(:work_settings, :work_settings_model_accounts_valid))

    alter table(:work_settings) do
      remove(:model_accounts)
    end
  end

  # One dimension, one to `most` entries, none of them null, each matching
  # `entry` exactly. An entry holds no spaces, so the entries joined by one
  # space match the pattern repeated only when every one of them does.
  defp list_check(column, entry, most) do
    """
    array_ndims(#{column}) = 1 AND cardinality(#{column}) BETWEEN 1 AND #{most} AND
    array_position(#{column}, NULL) IS NULL AND
    array_to_string(#{column}, ' ') ~ '^#{entry}( #{entry})*$'
    """
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
