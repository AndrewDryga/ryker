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
end
