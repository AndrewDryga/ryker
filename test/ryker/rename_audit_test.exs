defmodule Ryker.RenameAuditTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The product was renamed from Responder to Ryker on 2026-09-13. Every occurrence
  of the old name that remains in the tracked tree is either immutable evidence
  (harvested fixtures, recorded corpora, historical migrations, append-only logs)
  or a contract with another party that this repository cannot rename alone
  (co:op wire names and inbound webhook headers). Each is
  listed below with its reason; anything else is a rename that was missed, and
  this test fails on it so the old name cannot creep back through a new file,
  a pasted snippet or a "temporary" alias.
  """

  # Whole paths that are immutable evidence or renamed elsewhere. A path matched
  # here is not scanned at all.
  @immutable_paths [
    {~r{^testdata/},
     "harvested Slack and eval corpora, recorded tool catalogs and model results, and frozen co:op protocol schemas"},
    {~r{^test/.*/fixtures/.*\.json$},
     "recorded episodes, replies and threads (harvested, never invented)"},
    {~r{^test/.*/fixtures/README\.md$|\.PROVENANCE\.md$}, "provenance of the recorded fixtures"},
    {~r{^priv/repo/migrations/},
     "historical migrations create the objects under their old names; the 2026-09-13 migration renames them and earlier files stay exactly as they ran"},
    {~r{^CHANGELOG\.md$}, "append-only release history"},
    {~r{^lib/ryker/retained\.ex$},
     "the one module that names retained stored values (Work session external_ref prefix, system source ref, Slack action prefix); each constant carries its own reason"},
    {~r{^test/ryker/rename_audit_test\.exs$}, "this allowlist"}
  ]

  # One document section that must name the remaining pre-rename names in
  # full. It runs from its heading to the next heading of the same level;
  # nothing outside it in that file is exempt.
  @immutable_sections [
    {"docs/operations.md", "## Names that still say responder",
     "the operator's list of pre-rename names another party owns (co:op and webhook senders) and the stored values the code still recognises"}
  ]

  # Tokens allowed everywhere else. `path` narrows an entry to the files where
  # the token is a deliberate reference; `~r//` on `path` means any file.
  @allowed_tokens [
    # --- contracts with another party
    {~r//, ~r/responder-state(?![A-Za-z0-9_])|responder-state:v1/,
     "co:op capability and MCP server name (and its contract version); renamed only with a coordinated co:op release"},
    {~r//, ~r/responder_binding|responder_state_tools/,
     "co:op command protocol JSON keys, and the functions and atoms that carry them"},
    {~r//, ~r/x-responder-(artifact|checkpoint)-(name|sha256|descriptor)/,
     "worker gateway headers read by the co:op worker"},
    {~r//, ~r/x-responder-(signature|timestamp|event-id|event-type|item-id|occurred-at|revision)/,
     "inbound webhook contract; configured external senders set these headers"},
    {~r//, ~r/responder\.publication_lifecycle\.v1/,
     "inbound webhook event type set by external senders"},
    {~r//, ~r/responder-delivery:/,
     "GitHub comment marker that keeps already-posted comments idempotent; changing it would repost every delivered comment"},
    # --- evidence and history named outside the immutable paths
    {~r{^lib/ryker/episodes/replay\.ex$|^test/ryker/(admission|episodes)/replay_test\.exs$},
     ~r/responder\.db/,
     "Go-era SQLite state file: the recorded episode fixtures name it as their harvest provenance (source.database)"},
    {~r{^docs/control-plane\.md$}, ~r/responder_(state|preferences)(?![A-Za-z0-9_])/,
     "Go-era SQLite tables named as the data source of the retained design notes"},
    {~r{^test/ryker/control_plane/subscription_presentation_test\.exs$}, ~r/responder_emisar/,
     "harvest provenance: the live database's name on the day the rows were taken"},
    {~r{^test/ryker/coop_fleet/protocol_test\.exs$}, ~r/responder-read-only-v1/,
     "policy name recorded in the frozen co:op worker protocol golden (testdata/protocol)"},
    # --- retained stored values exercised in tests of Ryker.Retained
    {~r{^test/ryker/slack/(app_home_controls|home_interaction)_test\.exs$}, ~r/responder-work:/,
     "external_ref prefix of Work sessions created before the rename (Ryker.Retained.work_session_prefix/0)"},
    {~r{^test/ryker/state/continuity_test\.exs$}, ~r/"responder"/,
     "source ref of system inputs recorded before the rename (Ryker.Retained.system_source_ref/0)"},
    {~r{^test/ryker/slack/(gateway|interaction|interaction_feedback)_test\.exs$},
     ~r{responder_(confirm_memory|home_open|investigate_message)|"/responder"},
     "action, callback and command ids registered before the rename, answered by the explicit retired paths"},
    # --- the one manifest assertion about the rename
    {~r{^docs/slack-app\.md$}, ~r{`/responder`},
     "the manifest update step names the command it replaces"},
    {~r{^test/ryker/slack/app_manifest_test\.exs$}, ~r/"responder"/,
     "asserts the manifest copy no longer names the old product"},
    {~r{^test/ryker/ingress/migration_upgrade_test\.exs$}, ~r/[Rr]esponder/,
     "the migration ladder test drives historical schema states by their names, including the rename migration's own up and down"},
    # --- the English word
    {~r//,
     ~r/\b(first|on-call|configured|coordinate|invited) responders?\b|\ba responder to read\b|\bresponders\b/i,
     "the English word for an on-call human, not the product"}
  ]

  test "every remaining occurrence of the old name is listed evidence or a documented contract" do
    root = Path.expand("../..", __DIR__)

    {output, 0} =
      System.cmd(
        "git",
        ["grep", "-I", "-i", "-n", "--untracked", "-e", "responder", "--", "."],
        cd: root,
        stderr_to_stdout: true
      )

    sections = section_ranges(root)

    violations =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&split_line/1)
      |> Enum.reject(fn {path, line, _text} ->
        immutable?(path) or in_section?(sections, path, line)
      end)
      |> Enum.flat_map(fn {path, line, text} ->
        text
        |> strip_allowed(path)
        |> then(fn rest -> if rest =~ ~r/responder/i, do: [{path, line, text}], else: [] end)
      end)

    assert violations == [],
           "old product name outside the documented allowlist:\n" <>
             Enum.map_join(violations, "\n", fn {path, line, text} ->
               "  #{path}:#{line}: #{String.trim(text)}"
             end)
  end

  test "every allowlist entry still matches something, so a stale reason cannot hide a new use" do
    root = Path.expand("../..", __DIR__)

    {output, 0} =
      System.cmd("git", ["grep", "-I", "-i", "-l", "--untracked", "-e", "responder", "--", "."],
        cd: root
      )

    paths = String.split(output, "\n", trim: true)

    stale_paths =
      Enum.reject(@immutable_paths, fn {pattern, _reason} ->
        Enum.any?(paths, &(&1 =~ pattern))
      end)

    assert stale_paths == [], "immutable path patterns without a match: #{inspect(stale_paths)}"

    stale_sections =
      Enum.reject(section_ranges(root), fn {_path, first.._last//_step} -> first > 0 end)

    assert stale_sections == [], "runbook sections without a heading: #{inspect(stale_sections)}"

    {lines, 0} =
      System.cmd("git", ["grep", "-I", "-i", "-n", "--untracked", "-e", "responder", "--", "."],
        cd: root
      )

    sections = section_ranges(root)

    scanned =
      lines
      |> String.split("\n", trim: true)
      |> Enum.map(&split_line/1)
      |> Enum.reject(fn {path, line, _text} ->
        immutable?(path) or in_section?(sections, path, line)
      end)

    stale_tokens =
      Enum.reject(@allowed_tokens, fn {path_pattern, token, _reason} ->
        Enum.any?(scanned, fn {path, _line, text} -> path =~ path_pattern and text =~ token end)
      end)

    assert stale_tokens == [],
           "allowed tokens that no longer occur anywhere: " <>
             Enum.map_join(stale_tokens, ", ", fn {_path, token, _reason} -> inspect(token) end)
  end

  defp split_line(line) do
    [path, number, text] = String.split(line, ":", parts: 3)
    {path, String.to_integer(number), text}
  end

  defp immutable?(path),
    do: Enum.any?(@immutable_paths, fn {pattern, _reason} -> path =~ pattern end)

  # {path, first_line..last_line} of each immutable section; 0..0 when the
  # heading is missing, which the stale-entry test reports.
  defp section_ranges(root) do
    Enum.map(@immutable_sections, fn {path, heading, _reason} ->
      lines = root |> Path.join(path) |> File.read!() |> String.split("\n")
      {path, section_range(lines, heading, Enum.find_index(lines, &(&1 == heading)))}
    end)
  end

  defp section_range(_lines, _heading, nil), do: 0..0//1

  defp section_range(lines, heading, index) do
    level = heading |> String.split(" ") |> hd()
    rest = Enum.drop(lines, index + 1)

    last =
      case Enum.find_index(rest, &String.starts_with?(&1, level <> " ")) do
        nil -> length(lines)
        offset -> index + 1 + offset
      end

    (index + 1)..last//1
  end

  defp in_section?(sections, path, line),
    do:
      Enum.any?(sections, fn {section_path, range} -> section_path == path and line in range end)

  defp strip_allowed(text, path) do
    Enum.reduce(@allowed_tokens, text, fn {path_pattern, token, _reason}, rest ->
      if path =~ path_pattern, do: Regex.replace(token, rest, ""), else: rest
    end)
  end
end
