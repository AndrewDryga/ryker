defmodule Ryker.RedactionAuditTest do
  use ExUnit.Case, async: true

  @moduledoc """
  This repository is public, and the harvested corpora in `testdata/` and
  `test/**/fixtures/` are real Slack history. They were published for weeks
  carrying the operated tenant's actual workspace, channel, user, app and
  subteam identifiers, because `Ryker.InspectionRedactor` removes
  credential-shaped values and nothing else: a workspace id does not look like
  a secret. One harvest that forgets the substitution puts them back.

  So the identifiers the corpus may contain are allowlisted here rather than
  denylisted. A denylist would have to name the real identifiers to forbid
  them, which is the disclosure it is trying to prevent, and would say nothing
  about the next workspace. Every canonical Slack identifier in the tree must
  appear below with the reason it is safe to publish; a fresh harvest fails
  this test instead of reaching a commit.

  Add new pseudonyms to `@pseudonyms` as the corpus grows. Never widen an entry
  to a shape like `~r/^U0/`, which would admit every real user id and leave
  this test passing while proving nothing.

  Scope and its limit: this matches the canonical eleven-character form
  (`T0`/`C0`/`U0`/`B0`/`A0`/`S0` and nine more), which is the shape every
  identifier in this corpus has ever used. Slack also issues longer ids, and
  one of those would pass unseen. This is a tripwire on the documented harvest
  path, not a proof of absence. It also cannot see ignored paths such as
  `.agent/tasks/`, where a local extractor's output is never committed.
  """

  # The invented tenant. `docs/memory-evaluation.md` records the substitution
  # these replaced and why the behaviour the fixtures hold shut is unchanged.
  @pseudonyms %{
    "T0TENANT001" => "pseudonymous tenant workspace",
    "C0TENANTOPS" => "pseudonymous tenant channel: monitoring and alerts",
    "C0TENANTENG" => "pseudonymous tenant channel: engineering",
    "C0TENANTREL" => "pseudonymous tenant channel: releases",
    "C0TENANTGEN" => "pseudonymous tenant channel: general",
    "C0TENANTAL1" => "pseudonymous tenant channel: alert cycle fixtures",
    "C0TENANTAL2" => "pseudonymous tenant channel: alert cycle fixtures",
    "C0TENANTAL3" => "pseudonymous tenant channel: alert cycle fixtures",
    "C0TENANTTF1" => "pseudonymous tenant channel: Terraform run fixtures",
    "C0TENANTWT1" => "pseudonymous tenant channel: input wait fixtures",
    "U0TENANTUS1" => "pseudonymous tenant member",
    "U0TENANTUS2" => "pseudonymous tenant member",
    "U0TENANTUS3" => "pseudonymous tenant member",
    "U0TENANTUS4" => "pseudonymous tenant member",
    "U0TENANTUS5" => "pseudonymous tenant member",
    "U0TENANTUS6" => "pseudonymous tenant member",
    "U0TENANTUS7" => "pseudonymous tenant member",
    "U0TENANTUS8" => "pseudonymous tenant member",
    "U0TENANTUS9" => "pseudonymous tenant member",
    "B0TENANTBT1" => "pseudonymous bot user of an app installed in the tenant workspace",
    "B0TENANTBT2" => "pseudonymous bot user of an app installed in the tenant workspace",
    "B0TENANTBT3" => "pseudonymous bot user of an app installed in the tenant workspace",
    "B0TENANTBT4" => "pseudonymous bot user of an app installed in the tenant workspace",
    "B0TENANTBT5" => "pseudonymous bot user of an app installed in the tenant workspace",
    "A0TENANTAP1" => "pseudonymous app installed in the tenant workspace",
    "S0TENANTQA1" => "pseudonymous tenant subteam"
  }

  # Shapes that are plainly not anyone's workspace.
  @placeholders %{
    "T0123456789" => "digit-run placeholder",
    "C0123456789" => "digit-run placeholder",
    "U0123456789" => "digit-run placeholder",
    "A0123456789" => "digit-run placeholder",
    "B0123456789" => "digit-run placeholder",
    "C0DEMOROOM1" => "named placeholder: demo channel",
    "C0TEST00001" => "named placeholder: test channel",
    "U0DANA00001" => "named placeholder: this corpus's synthetic person",
    "U0FEEDBACK1" => "named placeholder: feedback author",
    "B0ANNOUNCED" => "named placeholder: announcing bot"
  }

  # First-party and real: this project's own Slack app and the development
  # workspace it is installed in. Published deliberately, and in scope only if
  # the operator decides to pseudonymize their own workspace too.
  @first_party %{
    "T0BHXKZJVDX" => "Ryker's own development workspace",
    "C0BLU1GACKC" => "channel in Ryker's own development workspace",
    "C0BHTRPHXP0" => "channel in Ryker's own development workspace",
    "U0BHTNFCW6S" => "member of Ryker's own development workspace",
    "U0BL8MNPUSY" => "member of Ryker's own development workspace",
    "U0C1LCVNF52" => "member of Ryker's own development workspace",
    "B0BHPQTBMA7" => "Ryker's own bot user",
    "B0BL6UD7F0R" => "Ryker's own bot user",
    "A0BL6UCCBGR" => "Ryker's own Slack app",
    "C0BL6UCCBGR" => "Ryker's own app id reused as a channel-shape example in SourceRef tests"
  }

  @allowed Map.merge(@first_party, Map.merge(@pseudonyms, @placeholders))

  @identifier ~r/\b[TCUBAS]0[A-Z0-9]{9}\b/

  # `git grep` only narrows the tree to candidate lines and `@identifier`
  # decides. Apple's git does not know `\b` in an extended regex and matched
  # nothing, so the scan found no lines at all on macOS while passing on Linux.
  @candidate_line "[TCUBAS]0[A-Z0-9]{9}"

  test "every Slack identifier in the tree is an allowlisted pseudonym, placeholder or first-party id" do
    violations =
      for {path, line, text} <- scan(),
          identifier <- Regex.scan(@identifier, text) |> List.flatten() |> Enum.uniq(),
          not Map.has_key?(@allowed, identifier),
          do: {path, line, identifier}

    assert violations == [],
           "unallowlisted Slack identifiers; a harvest must substitute these before it is committed:\n" <>
             Enum.map_join(violations, "\n", fn {path, line, identifier} ->
               "  #{path}:#{line}: #{identifier}"
             end)
  end

  test "every allowlist entry still occurs, so a stale reason cannot shelter a new identifier" do
    present =
      scan()
      |> Enum.flat_map(fn {_path, _line, text} ->
        @identifier |> Regex.scan(text) |> List.flatten()
      end)
      |> MapSet.new()

    stale = @allowed |> Map.keys() |> Enum.reject(&MapSet.member?(present, &1)) |> Enum.sort()

    assert stale == [],
           "allowlisted identifiers that no longer occur anywhere; drop them rather than " <>
             "leaving a reason that shelters a future paste: #{Enum.join(stale, ", ")}"
  end

  # Free-text identities (an organization, its repositories, a person, a host) have no shape to
  # allowlist, and listing them here would publish them. The operator keeps them in an ignored
  # file, one per line, and this fails when any reaches a tracked file. Commits after the
  # 2026-10-01 substitution put the tenant's organization and repository names back into comments
  # and tests, and nothing above could see it (2026-10-04). CI writes the file from the
  # RYKER_REDACTION_DENYLIST secret before the gate; a checkout without either checks nothing here.
  @private_names Path.expand("../../.ryker/redaction-denylist", __DIR__)

  test "no name the operator keeps private reaches a tracked file" do
    names =
      case File.read(@private_names) do
        {:ok, text} ->
          text
          |> String.split("\n")
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))

        {:error, :enoent} ->
          []
      end

    if names != [] do
      {output, status} =
        System.cmd(
          "git",
          ["grep", "-I", "-l", "-i", "-F"] ++ Enum.flat_map(names, &["-e", &1]) ++ ["--", "."],
          cd: Path.expand("../..", __DIR__)
        )

      # git grep answers 1 when nothing matched. The names stay out of the message.
      assert {status, output} == {1, ""},
             "a privately listed name reached these tracked files:\n" <> output
    end
  end

  # CI's checkout has no ignored file, so until 2026-10-06 the check above found nothing to
  # refuse there, and a private name pushed from anywhere but the main checkout reached the
  # public repository unseen. Every workflow that runs the gate writes the names first.
  test "every workflow that runs the gate gives the audit the private names first" do
    for workflow <- Path.wildcard(Path.expand("../../.github/workflows/*.yml", __DIR__)),
        text = File.read!(workflow),
        String.contains?(text, "run: make check") do
      names = :binary.match(text, "secrets.RYKER_REDACTION_DENYLIST")
      written = :binary.match(text, ">.ryker/redaction-denylist")
      gate = :binary.match(text, "run: make check")

      assert names != :nomatch and written != :nomatch, "#{workflow} does not write the names"
      assert elem(written, 0) < elem(gate, 0), "#{workflow} writes the names after the gate"
    end
  end

  defp scan do
    root = Path.expand("../..", __DIR__)

    {output, 0} =
      System.cmd(
        "git",
        ["grep", "-I", "-n", "--untracked", "-E", "-e", @candidate_line, "--", "."],
        cd: root
      )

    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [path, number, text] = String.split(line, ":", parts: 3)
      {path, String.to_integer(number), text}
    end)
    # This file is the allowlist; its own entries are not findings.
    |> Enum.reject(fn {path, _line, _text} ->
      path == "test/ryker/redaction_audit_test.exs"
    end)
  end
end
