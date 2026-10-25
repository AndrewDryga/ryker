defmodule Ryker.Repo.Migrations.SeparateForgottenFactKeys do
  use Ecto.Migration

  # A model's valid key could equal a forgotten kind's digest. Reusing it
  # overwrote an unrelated kept fact; forgetting could fail the unique index.
  # Move only the digest prefix, keeping the row and all withdrawal custody.
  def up do
    drop(constraint(:person_facts, :person_facts_valid))

    execute("""
    UPDATE #{qualified("person_facts")}
    SET key = '~' || substring(key FROM 2)
    WHERE status = 'forgotten'
    """)

    check = validity("^~[0-9a-f]{47}$")
    create(constraint(:person_facts, :person_facts_valid, check: check))
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM #{qualified("person_facts")} forgotten
        JOIN #{qualified("person_facts")} kept
          ON kept.person_ref = forgotten.person_ref
          AND kept.key = 'f' || substring(forgotten.key FROM 2)
        WHERE forgotten.status = 'forgotten' AND kept.status = 'kept'
      ) THEN
        RAISE EXCEPTION 'personal fact keys overlap the previous namespace; rollback cannot preserve both facts';
      END IF;
    END
    $$
    """)

    drop(constraint(:person_facts, :person_facts_valid))

    execute("""
    UPDATE #{qualified("person_facts")}
    SET key = 'f' || substring(key FROM 2)
    WHERE status = 'forgotten'
    """)

    check = validity("^[a-z][a-z0-9-]{0,47}$")
    create(constraint(:person_facts, :person_facts_valid, check: check))
  end

  defp validity(forgotten_key_pattern) do
    """
    char_length(person_ref) BETWEEN 1 AND 1024
    AND char_length(source_message_ref) BETWEEN 1 AND 1024
    AND char_length(conversation_ref) BETWEEN 1 AND 1024
    AND COALESCE(
      CASE status
        WHEN 'kept' THEN
          key ~ '^[a-z][a-z0-9-]{0,47}$'
          AND char_length(fact) BETWEEN 1 AND 280 AND forgotten_at IS NULL
        WHEN 'forgotten' THEN
          key ~ '#{forgotten_key_pattern}' AND fact IS NULL AND forgotten_at IS NOT NULL
      END,
      false
    )
    """
  end

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
