defmodule Ryker.Repo.Migrations.OneSpellingForAChatPerson do
  use Ecto.Migration

  # A Chat reaction recorded its person as `control-plane:user:`, while the
  # person a turn is for is `control_plane:user:`, so one person had two
  # references (2026-10-04 review). Reactions use the one spelling since
  # 2026-10-06, and the four kept with the other move to it; a reaction's
  # episode event keeps what it recorded until retention prunes it.

  def up do
    execute("""
    UPDATE answer_feedback
    SET actor_ref = 'control_plane:user:' || substr(actor_ref, char_length('control-plane:user:') + 1)
    WHERE actor_ref LIKE 'control-plane:user:%'
    """)
  end

  def down, do: :ok
end
