defmodule Ryker.Repo.Migrations.PeopleSignInToTheConsole do
  use Ecto.Migration

  # The console signs people in itself (Andrew, 2026-10-13: "we should not use CF or anything
  # else for auth - we can do it ourselves, CF/Tailscale should be only used for tunneling").
  # A link signs one person in once: an operator asks Ryker for one in Slack, the host prints
  # one for its owner, and anyone signed in can invite someone outside Slack. A session is one
  # browser a link signed in. Both keep the SHA-256 of their token, never the token, and both
  # leave once they expire.

  @person """
  (person_via = ANY (ARRAY['slack_operator'::text, 'invite'::text, 'owner'::text]))
  AND (char_length(person_login) BETWEEN 1 AND 200)
  AND (char_length(person_name) BETWEEN 1 AND 120)
  AND (token_sha256 ~ '^[0-9a-f]{64}$'::text)
  """

  def change do
    create table(:console_sign_in_links, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:token_sha256, :text, null: false)
      add(:purpose, :text, null: false)
      add(:person_via, :text, null: false)
      add(:person_login, :text, null: false)
      add(:person_name, :text, null: false)
      add(:created_by, :text, null: false)
      add(:return_to, :text)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:used_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:console_sign_in_links, [:token_sha256]))
    create(index(:console_sign_in_links, [:expires_at]))

    # An invite names someone new; every other link signs in someone Slack or the host vouches
    # for. A link goes back only to a page of the console.
    create(
      constraint(:console_sign_in_links, :console_sign_in_link_valid,
        check: """
        #{@person}
        AND (purpose = ANY (ARRAY['sign_in'::text, 'invite'::text]))
        AND ((purpose = 'invite'::text) = (person_via = 'invite'::text))
        AND (char_length(created_by) BETWEEN 1 AND 256)
        AND ((return_to IS NULL) OR ((char_length(return_to) BETWEEN 1 AND 2048)
          AND (return_to ~ '^/[^/\\\\]'::text OR return_to = '/'::text)))
        AND (expires_at > inserted_at)
        AND ((used_at IS NULL) OR (used_at >= inserted_at))
        """
      )
    )

    create table(:console_sessions, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:token_sha256, :text, null: false)
      add(:person_via, :text, null: false)
      add(:person_login, :text, null: false)
      add(:person_name, :text, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:last_seen_at, :utc_datetime_usec, null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:console_sessions, [:token_sha256]))
    create(index(:console_sessions, [:expires_at]))

    create(
      constraint(:console_sessions, :console_session_valid,
        check: "#{@person} AND (expires_at > inserted_at)"
      )
    )
  end
end
