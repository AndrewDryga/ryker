defmodule Ryker.Repo.Migrations.KeepRepositoryKnowledgeInRyker do
  use Ecto.Migration

  # Andrew, 2026-09-28: "Since we refresh repo knowledge daily should we save
  # its state locally instead of DB? I don't want to make daily PRs to update
  # those files." Ryker already kept each repository's RYKER.md in
  # repository_knowledge, and proposed it besides in a draft pull request,
  # which Work followed through a copy on the repository's settings row until
  # it was merged. It proposes nothing now: a document is the repository's
  # knowledge the moment a run writes it, and Work is briefed with it from
  # here (`Ryker.Work.SubmissionBuilder`).
  #
  # What only served proposing goes: the pull request each entry followed,
  # how its document reached GitHub, the sha256 of each document sent to a
  # pull request's branch, and Work's copy on the settings row, which followed
  # the pull request and the RYKER.md on the default branch. Every document
  # and every run stays.
  #
  # A document written and not yet proposed is the repository's knowledge
  # now, until tomorrow's check. An entry whose last step failed on proposing
  # or on the repository's own RYKER.md (a pull request GitHub refused or a
  # person edited, an archived repository, a RYKER.md Ryker could not read)
  # no longer has that reason, and is checked at once; so is one Ryker never
  # wrote a document for, since a RYKER.md a person keeps in the repository no
  # longer holds Ryker's own back.
  #
  # Rolling back puts the columns back empty and Work's copy back from each
  # document, as the one last proposed; the previous release proposes each
  # document again at its next check.

  @proposing_errors ~w(github_archived github_pull_request_refused
    repository_knowledge_proposal_edited repository_knowledge_unreadable)

  def up do
    execute("""
    UPDATE #{qualified("repository_knowledge")}
    SET phase = 'idle', next_attempt_at = NULL, start_count = 0,
        next_check_at = clock_timestamp() + interval '1 day'
    WHERE phase = 'publish'
    """)

    execute("""
    UPDATE #{qualified("repository_knowledge")}
    SET error_code = CASE WHEN error_code IN (#{quoted(@proposing_errors)}) THEN NULL
                          ELSE error_code END,
        error = CASE WHEN error_code IN (#{quoted(@proposing_errors)}) THEN NULL ELSE error END,
        next_check_at = CASE WHEN phase = 'idle' THEN clock_timestamp() ELSE next_check_at END
    WHERE error_code IN (#{quoted(@proposing_errors)}) OR (phase = 'idle' AND document IS NULL)
    """)

    drop(constraint(:repository_knowledge, :repository_knowledge_valid))
    drop(constraint(:repository_knowledge, :repository_knowledge_sent_valid))

    alter table(:repository_knowledge) do
      remove(:published_at)
      remove(:publication)
      remove(:sent_sha256s)
      remove(:pull_request_url)
      remove(:pull_request_number)
      remove(:pull_request_state)
    end

    create(
      constraint(:repository_knowledge, :repository_knowledge_valid,
        check: entry_check(~w(idle write), "")
      )
    )

    drop(constraint(:repository_settings, :repository_knowledge_valid))

    alter table(:repository_settings) do
      remove(:knowledge_pull_request_url)
      remove(:knowledge_content)
      remove(:knowledge_status)
      remove(:knowledge_source_commit)
      remove(:knowledge_sha256)
    end
  end

  def down do
    alter table(:repository_settings) do
      add(:knowledge_pull_request_url, :text)
      add(:knowledge_content, :text)
      add(:knowledge_status, :text)
      add(:knowledge_source_commit, :text)
      add(:knowledge_sha256, :text)
    end

    execute("""
    UPDATE #{qualified("repository_settings")} AS repository
    SET knowledge_content = entry.document, knowledge_status = 'proposed',
        knowledge_source_commit = entry.document_commit,
        knowledge_sha256 = entry.document_sha256
    FROM #{qualified("repository_knowledge")} AS entry
    WHERE entry.repository_ref = repository.ref AND entry.document IS NOT NULL
    """)

    create(
      constraint(:repository_settings, :repository_knowledge_valid,
        check: """
        (knowledge_status IS NULL AND knowledge_content IS NULL
          AND knowledge_source_commit IS NULL AND knowledge_sha256 IS NULL)
        OR (knowledge_status IN ('accepted', 'proposed') AND knowledge_content IS NOT NULL
          AND knowledge_source_commit ~ '^[0-9a-f]{40}$'
          AND knowledge_sha256 ~ '^[0-9a-f]{64}$')
        """
      )
    )

    drop(constraint(:repository_knowledge, :repository_knowledge_valid))

    alter table(:repository_knowledge) do
      add(:published_at, :utc_datetime_usec)
      add(:publication, :text)
      add(:sent_sha256s, {:array, :text}, null: false, default: [])
      add(:pull_request_url, :text)
      add(:pull_request_number, :bigint)
      add(:pull_request_state, :text)
    end

    create(
      constraint(:repository_knowledge, :repository_knowledge_valid,
        check:
          entry_check(~w(idle write publish), """
          AND (phase <> 'publish' OR document IS NOT NULL)
          AND (published_at IS NULL OR document IS NOT NULL)
          AND (published_at IS NULL) = (publication IS NULL)
          AND (publication IS NULL OR publication IN ('opened', 'updated', 'unchanged'))
          AND (pull_request_url IS NULL OR pull_request_url ~ '^https://')
          AND (pull_request_number IS NULL OR pull_request_number > 0)
          AND (pull_request_url IS NULL) = (pull_request_number IS NULL)
          AND (pull_request_url IS NULL) = (pull_request_state IS NULL)
          AND (pull_request_state IS NULL OR pull_request_state IN ('open', 'merged', 'closed'))
          """)
      )
    )

    create(
      constraint(:repository_knowledge, :repository_knowledge_sent_valid,
        check: "array_to_string(sent_sha256s, ',', '-') ~ '^([0-9a-f]{64}(,[0-9a-f]{64})*)?$'"
      )
    )
  end

  # What every entry holds to, whatever it proposed, then `more`.
  defp entry_check(phases, more) do
    """
    char_length(repository_ref) BETWEEN 1 AND 64
    AND phase IN (#{quoted(phases)})
    AND start_count BETWEEN 0 AND start_limit AND start_limit BETWEEN 1 AND 8
    AND (lease_ref IS NULL) = (lease_owner IS NULL)
    AND (lease_ref IS NULL) = (lease_expires_at IS NULL)
    AND (lease_owner IS NULL OR char_length(lease_owner) BETWEEN 1 AND 1024)
    AND (reason IS NULL OR char_length(reason) BETWEEN 1 AND 512)
    AND (requested_by IS NULL OR char_length(requested_by) BETWEEN 1 AND 256)
    AND (document IS NULL) = (document_sha256 IS NULL)
    AND (document IS NULL) = (document_commit IS NULL)
    AND (document IS NULL) = (document_by IS NULL)
    AND (document IS NULL) = (document_at IS NULL)
    AND (document IS NULL OR octet_length(document) BETWEEN 1 AND 128000)
    AND (document_sha256 IS NULL OR document_sha256 ~ '^[0-9a-f]{64}$')
    AND (document_commit IS NULL OR document_commit ~ '^[0-9a-f]{40}$')
    AND (document_by IS NULL OR document_by IN ('model', 'outline'))
    AND (dropped_count IS NULL OR dropped_count >= 0)
    AND (error_code IS NULL) = (error IS NULL)
    AND (error_code IS NULL OR char_length(error_code) BETWEEN 1 AND 128)
    AND (error IS NULL OR char_length(error) BETWEEN 1 AND 1024)
    #{more}
    """
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
