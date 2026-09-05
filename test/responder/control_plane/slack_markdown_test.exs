defmodule Responder.ControlPlane.SlackMarkdownTest do
  use ExUnit.Case, async: true
  alias Responder.ControlPlane.SlackMarkdown

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
