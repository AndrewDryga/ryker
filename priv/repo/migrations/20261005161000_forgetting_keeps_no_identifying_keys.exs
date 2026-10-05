defmodule Ryker.Repo.Migrations.ForgettingKeepsNoIdentifyingKeys do
  use Ecto.Migration

  # A forgotten person fact kept its kind, such as "medical-leave", and a
  # forgotten topic its key and anchors, each saying what was forgotten
  # (2026-10-04 review). What was forgotten before now keeps what a forgetting
  # writes now: a digest of the fact's kind (`Ryker.People`), which still stops
  # anything said before from teaching it again, and a retired topic key with
  # no anchors (`Ryker.Memories.Forgetting`).
  def up do
    execute("""
    UPDATE person_facts
    SET key = 'f' || left(encode(sha256(convert_to(person_ref || chr(10) || key, 'UTF8')), 'hex'), 47)
    WHERE status = 'forgotten' AND key !~ '^f[0-9a-f]{47}$'
    """)

    execute("""
    UPDATE conversation_knowledge
    SET topic_key = 'retired:' || id::text, anchor_keys = ARRAY[]::text[]
    WHERE forgotten_at IS NOT NULL AND topic_key NOT LIKE 'retired:%'
    """)
  end

  def down, do: :ok
end
