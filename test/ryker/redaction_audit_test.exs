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
