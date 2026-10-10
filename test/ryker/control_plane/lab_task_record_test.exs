defmodule Ryker.ControlPlane.LabTaskRecordTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.HTML

  @pull_request "https://github.com/AndrewDryga/test/pull/8"

  # Manual test, 2026-10-09: a Chat task's Timeline, Evidence, Handoff and
  # Postmortem pages printed the record they share with Slack raw, in a <pre>:
  # "*Timeline*", "<!date^1791521461^{date_short} {time}|9 Oct 04:51 UTC>" and
  # "<https://github.com/AndrewDryga/test/pull/8|#8>", under the words
  # "Host-rendered task record". The body is the harvested timeline of the task
  # that opened AndrewDryga/test#8.
  test "a task record page reads as text, not as Slack markup" do
    body = """
    *Timeline* · Add manual QA note to README
    Now: Completed
    • <!date^1791521461^{date_short} {time}|9 Oct 04:51 UTC>  Message added
    • <!date^1791521575^{date_short} {time}|9 Oct 04:52 UTC>  Draft PR <#{@pull_request}|#8> · open
    """

    for kind <- [:timeline, :evidence, :handoff, :postmortem] do
      page = render(%{body: body, kind: kind, navigation: [], title: "Task timeline"})
      text = LazyHTML.text(page)

      refute text =~ "<!date"
      refute text =~ "*Timeline*"
      refute text =~ "Host-rendered"
      assert text =~ "9 Oct 04:51 UTC  Message added"
      assert page |> LazyHTML.query("strong") |> LazyHTML.text() == "Timeline"
      assert page |> LazyHTML.query("a[href='#{@pull_request}']") |> LazyHTML.text() == "#8"
    end
  end

  test "a diff page keeps its patch as written" do
    patch = "Patch page:\ndiff --git a/README.md b/README.md\n+Manual QA run on 2026-10-09.\n"
    page = render(%{body: patch, kind: :diff, navigation: [], title: "Task changes"})

    assert page |> LazyHTML.query("pre") |> LazyHTML.text() == patch
  end

  defp render(snapshot) do
    snapshot
    |> HTML.lab_task_record()
    |> IO.iodata_to_binary()
    |> LazyHTML.from_fragment()
  end
end
