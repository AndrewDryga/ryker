defmodule Ryker.ControlPlane.SlackMarkdownTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.SlackMarkdown

  test "Slack alert dates and underscored identifiers remain readable" do
    # The OOM source rendered raw date syntax and italicized half of CONSTRAINT_MEMCG.
    text =
      "CONSTRAINT_MEMCG. CONSTRAINT_MEMCG means a cgroup limit.\n<!date^1788629330^{date_short_pretty} at {time_secs}|2026-09-05 17:28:50 UTC>"

    html = SlackMarkdown.render(text) |> IO.iodata_to_binary()
    assert html =~ "CONSTRAINT_MEMCG. CONSTRAINT_MEMCG"
    assert html =~ "2026-09-05 17:28:50 UTC"
    refute html =~ "&lt;!date"
    refute html =~ "<em>"
  end

  test "answer previews render recorded Markdown links and lists without activating HTML" do
    # The infrastructure answer displayed literal evidence links instead of clickable receipts.
    html =
      SlackMarkdown.preview(
        "The check is **partial**.\n\n- Both are connected.\n- Health remains unverified.\n\n[Boot check: emisar-b3tg](https://emisar.dev/app/emisar/runs/01a07493-e351-7ba1-ad7a-5d4bd96be230)\n\n<script>bad</script> [bad](javascript:alert(1))"
      )
      |> IO.iodata_to_binary()

    assert html =~ "<strong>partial</strong>"
    assert html =~ "<ul><li>Both are connected.</li><li>Health remains unverified.</li></ul>"

    assert html =~
             ~s(href="https://emisar.dev/app/emisar/runs/01a07493-e351-7ba1-ad7a-5d4bd96be230")

    refute html =~ "<script>"
    refute html =~ ~s(href="javascript:)
  end

  # QA, 2026-09-25: a follow-up's numbered list read 1, 1, 1 in Chat. A list
  # whose items are separated by blank lines is split into paragraphs, and
  # each became its own list starting at 1. Each keeps the number it was
  # written with.
  test "a numbered list keeps its numbers when blank lines separate the items" do
    html =
      "Check these first:\n\n1. Probe errors\n\n2. Pod events\n3. Release changes"
      |> SlackMarkdown.preview()
      |> IO.iodata_to_binary()

    assert html =~ "<ol><li>Probe errors</li></ol>"
    assert html =~ ~s(<ol start="2"><li>Pod events</li><li>Release changes</li></ol>)
  end

  # Manual test, 2026-09-26: a model's numbered item whose text wrapped onto
  # an indented line, or which carried an indented sub-point, split the list:
  # the item ended, the wrapped words stood alone as a paragraph, and the
  # next item began a new list.
  test "a numbered item's wrapped line and its sub-points stay inside the item" do
    html =
      "1. **Deploy** check the release\n   notes before rolling back\n   - error rate\n   - latency\n2. Tell the channel"
      |> SlackMarkdown.preview()
      |> IO.iodata_to_binary()

    assert html ==
             "<ol><li><strong>Deploy</strong> check the release notes before rolling back" <>
               "<ul><li>error rate</li><li>latency</li></ul></li><li>Tell the channel</li></ol>"
  end

  test "an indented line under plain text is still plain text" do
    html =
      "Run this:\n    make check\nThen deploy."
      |> SlackMarkdown.preview()
      |> IO.iodata_to_binary()

    assert html == "<p>Run this:\n    make check\nThen deploy.</p>"
  end

  # QA re-test, 2026-09-26: "```sh" showed "sh" as the first line of the code.
  # The fence's first word names the language; it is not code.
  test "a fenced block's language names the block instead of becoming its first line" do
    html = "```sh\nls -la\n```" |> SlackMarkdown.preview() |> IO.iodata_to_binary()
    assert html == ~s(<pre class="md-code" data-language="sh"><code>ls -la</code></pre>)

    bare = "```\nmix test\n```" |> SlackMarkdown.preview() |> IO.iodata_to_binary()
    assert bare == ~s(<pre class="md-code"><code>mix test</code></pre>)

    inline = "```ls -la```" |> SlackMarkdown.preview() |> IO.iodata_to_binary()
    assert inline == ~s(<pre class="md-code"><code>ls -la</code></pre>)
  end

  test "unmatched formatting delimiters do not remove any source text" do
    Enum.each(
      ["*unfinished", "_unfinished", "~unfinished", "`unfinished", "```unfinished"],
      fn text ->
        assert SlackMarkdown.render(text) |> IO.iodata_to_binary() == text
      end
    )
  end

  test "Slack formatting is readable and HTML remains inert" do
    html =
      SlackMarkdown.render(
        "*Incident* _Provisioning_ ~stale~ `status`\n<https://example.test|Evidence> & <script>alert(1)</script>"
      )
      |> IO.iodata_to_binary()

    assert html =~ "<strong>Incident</strong>"
    assert html =~ "<em>Provisioning</em>"
    assert html =~ "<del>stale</del>"
    assert html =~ "<code>status</code>"
    assert html =~ ~s(href="https://example.test")
    assert html =~ "&lt;script&gt;"
    refute html =~ "<script>"
  end

  test "code is never recursively interpreted and non-web URLs cannot become links" do
    html =
      SlackMarkdown.render(
        "```*literal* <img src=x>``` <javascript:alert(1)|click> <https://example.test/?q=\"|safe>"
      )
      |> IO.iodata_to_binary()

    assert html =~ "<pre class=\"md-code\"><code>*literal* &lt;img src=x&gt;</code></pre>"
    refute html =~ "<strong>literal</strong>"
    refute html =~ ~s(href="javascript:)
    refute html =~ "<img"
    assert html =~ "&quot;"
  end
end
