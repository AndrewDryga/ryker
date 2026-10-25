defmodule Ryker.ControlPlane.MessageLinkReadabilityTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.SlackMarkdown

  test "an emphasized Slack destination remains a working link, not literal control syntax" do
    # The October 25 monitoring notification put its alert URL inside bold
    # text. The formatting renderer escaped that entire inner token, hiding
    # the only direct path to the alert in an otherwise readable message.
    for emphasis <- ["**", "*", "_", "~"] do
      html =
        SlackMarkdown.render(
          emphasis <> "<https://example.test/alert|View alert>" <> emphasis,
          nil
        )
        |> IO.iodata_to_binary()

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(document, "a") |> LazyHTML.attribute("href") == [
               "https://example.test/alert"
             ]

      assert LazyHTML.query(document, "a") |> LazyHTML.text() == "View alert"
    end
  end

  test "formatting never activates unsafe destinations or HTML" do
    html =
      SlackMarkdown.render("*<javascript:alert(1)|View alert> <script>no</script>*", nil)
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(html, "a, script"))
    assert LazyHTML.text(html) =~ "<script>no</script>"
  end
end
