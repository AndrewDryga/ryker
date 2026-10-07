defmodule Ryker.ControlPlane.LabMessageEditorTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.HTML

  # The editor's id was the message's id written into the page unescaped, so its safety rested
  # on every message id being plain (2026-10-04 review). It is escaped like every other value.
  test "a message id cannot write markup into its editor" do
    item_id = ~s{item" autofocus onfocus="alert(1)}

    html =
      %{
        message_controls: %{
          edit: %{conversation_id: "conversation", item_id: item_id, token: "t"}
        },
        item_id: item_id,
        text: "Stored body"
      }
      |> HTML.lab_message_editor()
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    editor = LazyHTML.query(html, "form.lab-edit-form")
    assert LazyHTML.attribute(editor, "id") == ["lab-edit-" <> item_id]
    assert LazyHTML.query(html, "[onfocus]") |> Enum.count() == 0

    assert LazyHTML.query(html, "textarea") |> LazyHTML.attribute("id") == [
             "lab-edit-#{item_id}-text"
           ]
  end

  # These controls are HTML built by hand, so their safety rests on each value
  # being escaped where it is written (IL-16). A body, the conversation's id,
  # the form tokens and a reaction's name all come from people or Slack.
  test "no field of a message can write markup into its controls" do
    hostile = ~s{x"><script>alert(1)</script><b onfocus="y}
    body = "</textarea><script>alert(2)</script>"

    controls = %{conversation_id: hostile, item_id: "item", token: hostile}

    message = %{
      message_controls: %{edit: controls, delete: controls},
      item_id: "item",
      text: body,
      ref: hostile,
      reaction_controls: %{
        conversation_id: hostile,
        message_ref: hostile,
        mine: "slack:user:U1",
        token: hostile
      },
      feedback_reactions: [%{emoji_name: hostile, actor_ref: "slack:user:U2"}]
    }

    html =
      [
        HTML.lab_message_editor(message),
        HTML.lab_message_actions(message),
        HTML.lab_message_reactions(message)
      ]
      |> IO.iodata_to_binary()
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(html, "script") |> Enum.count() == 0
    assert LazyHTML.query(html, "[onfocus]") |> Enum.count() == 0
    assert LazyHTML.query(html, "textarea") |> LazyHTML.text() == body

    tokens = html |> LazyHTML.query("input[name=_token]") |> LazyHTML.attribute("value")
    assert tokens != [] and Enum.uniq(tokens) == [hostile]
  end
end
