defmodule Responder.ControlPlane.SlackMarkdownTest do
  use ExUnit.Case, async: true
  alias Responder.ControlPlane.SlackMarkdown

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

    assert html =~ "<pre><code>*literal* &lt;img src=x&gt;</code></pre>"
    refute html =~ "<strong>literal</strong>"
    refute html =~ ~s(href="javascript:)
    refute html =~ "<img"
    assert html =~ "&quot;"
  end
end
