defmodule Ryker.RenameAuditTest do
  use ExUnit.Case, async: true

  @moduledoc """
  The product was renamed from Responder to Ryker on 2026-09-13. Every occurrence
  of the old name that remains in the tracked tree is either immutable evidence
  (harvested fixtures, recorded corpora, append-only logs)
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
    {~r{^CHANGELOG\.md$}, "append-only release history"},
    {~r{^test/ryker/rename_audit_test\.exs$}, "this allowlist"}
  ]

  # One document section that must name the remaining pre-rename names in
  # full. It runs from its heading to the next heading of the same level;
  # nothing outside it in that file is exempt.
  @immutable_sections [
    {"docs/operations.md", "## Names that still say responder",
     "the operator's list of pre-rename names another party owns or stored data carries"}
  ]

  # Tokens allowed everywhere else. `path` narrows an entry to the files where
  # the token is a deliberate reference; `~r//` on `path` means any file.
  @allowed_tokens [
    # --- contracts with another party
    {~r{^(lib/ryker/(control_plane/(tool_card|saved_records|episode_trace/tool_activity)|work/activity_event/query|state_tools/record_writer)|test/ryker/slack/reply_records_test)\.exs?$},
     ~r/responder-state(?![A-Za-z0-9_])|responder-state:v1/,
     "read-only historical activity and immutable state-record idempotency namespace; new execution uses controller-tools"},
    {~r{^(lib/ryker/control_plane/(model_requests|request_context_html)\.ex|test/ryker/control_plane/request_context_html_test\.exs)$},
     ~r/responder_state_tools/, "read-only inspection of previously saved prompt context"},
    {~r//, ~r/x-responder-(signature|timestamp|event-id|event-type|item-id|occurred-at|revision)/,
     "inbound webhook contract; configured external senders set these headers"},
    {~r//, ~r/responder\.publication_lifecycle\.v1/,
     "inbound webhook event type set by external senders"},
    # --- evidence and history named outside the immutable paths
    {~r{^test/support/episodes/replay\.ex$|^test/ryker/(admission|episodes)/replay_test\.exs$},
     ~r/responder\.db/,
     "Go-era SQLite state file: the recorded episode fixtures name it as their harvest provenance (source.database)"},
    {~r{^test/ryker/control_plane/subscription_presentation_test\.exs$}, ~r/responder_emisar/,
     "harvest provenance: the live database's name on the day the rows were taken"},
    # --- the one manifest assertion about the rename
    {~r{^docs/slack-app\.md$}, ~r{`/responder`},
     "the manifest update step names the command it replaces"},
    {~r{^test/ryker/slack/app_manifest_test\.exs$}, ~r/"responder"/,
     "asserts the manifest copy no longer names the old product"},
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

  defp in_section?(sections, path, line) do
    Enum.any?(sections, fn {section_path, range} -> section_path == path and line in range end)
  end

  defp strip_allowed(text, path) do
    Enum.reduce(@allowed_tokens, text, fn {path_pattern, token, _reason}, rest ->
      if path =~ path_pattern, do: Regex.replace(token, rest, ""), else: rest
    end)
  end
end
