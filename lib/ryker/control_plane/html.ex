defmodule Ryker.ControlPlane.HTML do
  @moduledoc false

  alias Phoenix.HTML.Safe

  alias Ryker.ControlPlane.{Card, ConversationLab, Layouts}

  # The title and description are the shell's header; the body owns the rest.
  @spec page(String.t(), String.t() | nil, iodata()) :: binary()
  def page(title, description, body) do
    %{__changed__: nil, title: title, description: description, body: IO.iodata_to_binary(body)}
    |> Layouts.static()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # The one body a missing page, record or action renders under the shell's
  # "Not found" title, on the live shell and the static one alike: it says the
  # thing is missing and offers a way back, never an empty list that would read
  # as the record's state.
  @spec not_found(String.t()) :: iodata()
  def not_found(subject) do
    [
      "<section class=\"document-unavailable\"><p>This ",
      escape(String.downcase(subject)),
      " does not exist or is no longer available. Check the link, or start again from Activity.</p>",
      "<a class=\"ui-button secondary\" href=\"/\">Back to activity</a></section>"
    ]
  end

  def lab_task_record(snapshot, back_path) do
    navigation =
      Enum.map(snapshot.navigation, fn item ->
        ["<a class=\"button\" href=\"", escape(item.path), "\">", escape(item.label), "</a>"]
      end)

    [
      "<section class=\"work-view\"><p class=\"eyebrow\">Host-rendered task record</p>",
      "<pre>",
      escape(snapshot.body),
      "</pre><div class=\"work-view-actions\">",
      "<a class=\"quiet-link\" href=\"",
      escape(back_path),
      "\">Back to conversation</a>",
      navigation,
      "</div></section>"
    ]
  end

  def confirmation(title, explanation, action, token, cancel_path) do
    [
      "<section class=\"confirm\" aria-label=\"",
      escape(title),
      "\"><p>",
      escape(explanation),
      "</p><form class=\"action-controls\" method=\"post\" action=\"",
      escape(action),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(token),
      "\"><button class=\"ui-button primary\" type=\"submit\">Confirm</button> ",
      "<a href=\"",
      escape(cancel_path),
      "\">Cancel</a></form></section>"
    ]
  end

  @doc false
  def lab_message_extras(message) do
    [
      "<div class=\"message-attachments\">",
      Enum.map(Map.get(message, :attachments, []), &lab_attachment/1),
      "</div>",
      lab_generated_files(Map.get(message, :generated_files, [])),
      "<div class=\"message-reactions\">",
      Enum.map(Map.get(message, :reactions, []), &lab_reaction/1),
      "</div>",
      "<div class=\"message-cards\">",
      Enum.map(Map.get(message, :cards, []), &lab_card/1),
      "</div>"
    ]
  end

  defp lab_generated_files([]), do: ""

  defp lab_generated_files(files) do
    [
      "<section class=\"lab-generated-files\"><h4>Generated files</h4><div class=\"message-attachments\">",
      Enum.map(files, &lab_attachment/1),
      "</div></section>"
    ]
  end

  @doc false
  # The inline editor of one operator message: a hidden form bound to that
  # message's exact edit route and token, holding the stored body, with Cancel
  # and Save at its lower edge. The page's script shows it in place of the
  # rendered body; nothing here is a disclosure, a heading or a second copy.
  def lab_message_editor(%{
        message_controls: %{
          edit: %{
            conversation_id: conversation_id,
            item_id: item_id,
            token: edit_token
          }
        },
        item_id: item_id,
        text: text
      })
      when is_binary(item_id) do
    editor_id = "lab-edit-#{item_id}"

    [
      "<form class=\"lab-edit-form\" id=\"",
      editor_id,
      "\" phx-submit=\"edit-lab-message\" data-lab-edit=\"",
      escape(item_id),
      "\" data-draft-action=\"message:",
      escape(item_id),
      "\" hidden><input type=\"hidden\" name=\"conversation_id\" value=\"",
      escape(conversation_id),
      "\"><input type=\"hidden\" name=\"item_id\" value=\"",
      escape(item_id),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(edit_token),
      "\"><label class=\"sr-only\" for=\"",
      editor_id,
      "-text\">Edit message</label><textarea id=\"",
      editor_id,
      "-text\" name=\"message\" maxlength=\"20000\" data-max-bytes=\"20000\" rows=\"1\">",
      escape(text),
      "</textarea><p class=\"lab-edit-error\" id=\"",
      editor_id,
      "-error\" role=\"alert\" hidden></p><div class=\"lab-edit-actions\">",
      "<span class=\"lab-edit-hint\">Enter adds a line · ⌘ / Ctrl + Enter saves · Esc cancels</span>",
      "<button type=\"button\" class=\"lab-edit-cancel\">Cancel</button>",
      "<button type=\"submit\" class=\"lab-edit-save\" phx-disable-with=\"Saving…\">Save</button></div></form>"
    ]
  end

  def lab_message_editor(_message), do: ""

  @doc false
  # The reactions row under a delivered reply, as in Slack: the recorded pills,
  # then the add-reaction button at the end of the row with its anchored picker.
  def lab_message_reactions(
        %{
          reaction_controls: %{
            conversation_id: conversation_id,
            message_ref: message_ref,
            token: token
          }
        } = message
      )
      when is_binary(conversation_id) and is_binary(message_ref) and is_binary(token) do
    [
      "<div class=\"lab-reactions\">",
      lab_reaction_pills(message),
      lab_reaction_picker(message),
      "</div>"
    ]
  end

  def lab_message_reactions(_message), do: ""

  @doc false
  # The compact action row under an operator message: Edit, which opens the
  # editor above, and its own exact Delete form.
  def lab_message_actions(%{
        message_controls: %{
          delete: %{
            conversation_id: conversation_id,
            item_id: item_id,
            token: delete_token
          }
        },
        item_id: item_id
      })
      when is_binary(item_id) do
    [
      "<div class=\"lab-message-actions\"><button type=\"button\" class=\"lab-edit-toggle\" aria-controls=\"lab-edit-",
      escape(item_id),
      "\" aria-expanded=\"false\">Edit</button><form class=\"lab-delete-form\" id=\"lab-delete-",
      escape(item_id),
      "\" phx-submit=\"delete-lab-message\"><input type=\"hidden\" name=\"conversation_id\" value=\"",
      escape(conversation_id),
      "\"><input type=\"hidden\" name=\"item_id\" value=\"",
      escape(item_id),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(delete_token),
      "\"><button class=\"lab-message-delete\" type=\"submit\" phx-disable-with=\"Deleting…\">Delete</button></form></div>"
    ]
  end

  def lab_message_actions(_message), do: ""

  @quick_reactions [{"+1", "👍"}, {"heart", "❤️"}, {"eyes", "👀"}, {"tada", "🎉"}, {"rocket", "🚀"}]

  # Recorded reactions on a reply as small pills: one per emoji with the count
  # the reaction contract provides (its current reactors), pressed when the
  # local operator is among them. Each pill posts the real add or remove for
  # that emoji to that exact reply. A reply with none renders nothing here.
  defp lab_reaction_pills(%{
         feedback_reactions: reactions,
         reaction_controls: %{
           conversation_id: conversation_id,
           message_ref: message_ref,
           token: token
         }
       })
       when is_list(reactions) and reactions != [] and is_binary(conversation_id) and
              is_binary(message_ref) and is_binary(token) do
    operator = ConversationLab.operator_actor_ref()

    pills =
      reactions
      |> Enum.group_by(& &1.emoji_name)
      |> Enum.sort_by(fn {emoji_name, _reactors} -> emoji_name end)
      |> Enum.map(fn {emoji_name, reactors} ->
        mine = Enum.any?(reactors, &(&1.actor_ref == operator))
        count = length(reactors)
        glyph = lab_emoji_glyph(emoji_name)
        form_id = "lab-reaction-" <> lab_short_digest(message_ref <> ":" <> emoji_name)

        [
          "<form class=\"lab-reaction-form lab-reaction-pill\" id=\"",
          form_id,
          "\" phx-submit=\"react-to-lab-message\"><input type=\"hidden\" name=\"conversation_id\" value=\"",
          escape(conversation_id),
          "\"><input type=\"hidden\" name=\"message_ref\" value=\"",
          escape(message_ref),
          "\"><input type=\"hidden\" name=\"_token\" value=\"",
          escape(token),
          "\"><input type=\"hidden\" name=\"action\" value=\"",
          if(mine, do: "remove", else: "add"),
          "\"><input type=\"hidden\" name=\"emoji\" value=\"",
          escape(emoji_name),
          "\"><button type=\"submit\" class=\"lab-reaction-pill-button\" aria-pressed=\"",
          if(mine, do: "true", else: "false"),
          "\" aria-label=\"",
          escape(
            ":#{emoji_name}: #{count} #{if count == 1, do: "reaction", else: "reactions"}, " <>
              if(mine, do: "remove yours", else: "add yours")
          ),
          "\"><span class=\"lab-reaction-glyph\" aria-hidden=\"true\">",
          escape(glyph),
          "</span><span class=\"lab-reaction-count\" aria-hidden=\"true\">",
          integer(count),
          "</span></button></form>"
        ]
      end)

    ["<div class=\"lab-reaction-pills\">", pills, "</div>"]
  end

  defp lab_reaction_pills(_message), do: ""

  # The add-reaction control, an icon with an accessible name and a tooltip,
  # and its anchored picker: the five quick choices and a custom-name form
  # whose label, field and Add button share one row and whose error slot is
  # tied to the field. The picker is ignored by live patches so an open picker
  # and a half-typed name survive a refresh.
  defp lab_reaction_picker(%{
         reaction_controls: %{
           conversation_id: conversation_id,
           message_ref: message_ref,
           token: token
         },
         ref: ref
       })
       when is_binary(conversation_id) and is_binary(message_ref) and is_binary(token) and
              is_binary(ref) do
    picker_id = "lab-reaction-picker-" <> lab_short_digest(ref)

    quick =
      Enum.map(@quick_reactions, fn {emoji_name, glyph} ->
        [
          "<form class=\"lab-reaction-form lab-reaction-quick\" id=\"",
          picker_id,
          "-",
          escape(emoji_name),
          "\" phx-submit=\"react-to-lab-message\"><input type=\"hidden\" name=\"conversation_id\" value=\"",
          escape(conversation_id),
          "\"><input type=\"hidden\" name=\"message_ref\" value=\"",
          escape(message_ref),
          "\"><input type=\"hidden\" name=\"_token\" value=\"",
          escape(token),
          "\"><input type=\"hidden\" name=\"action\" value=\"add\"><input type=\"hidden\" name=\"emoji\" value=\"",
          escape(emoji_name),
          "\"><button type=\"submit\" aria-label=\"",
          escape("React with :#{emoji_name}:"),
          "\">",
          escape(glyph),
          "</button></form>"
        ]
      end)

    [
      "<button type=\"button\" class=\"lab-reaction-toggle\" aria-label=\"Add reaction\" title=\"Add reaction\" aria-haspopup=\"true\" aria-expanded=\"false\" aria-controls=\"",
      picker_id,
      "\"><svg class=\"ui-icon\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><path d=\"M21 12a9 9 0 1 1-9-9 M8.5 14a4.5 4.5 0 0 0 7 0 M9 9.5h.01 M15 9.5h.01 M19 2v6 M16 5h6\"/></svg></button>",
      "<div class=\"lab-reaction-picker\" id=\"",
      picker_id,
      "\" role=\"group\" aria-label=\"Add a reaction\" phx-update=\"ignore\" hidden><div class=\"lab-reaction-quick-row\">",
      quick,
      "</div><form class=\"lab-reaction-form lab-reaction-custom\" id=\"",
      picker_id,
      "-custom\" phx-submit=\"react-to-lab-message\"><input type=\"hidden\" name=\"conversation_id\" value=\"",
      escape(conversation_id),
      "\"><input type=\"hidden\" name=\"message_ref\" value=\"",
      escape(message_ref),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(token),
      "\"><input type=\"hidden\" name=\"action\" value=\"add\"><label for=\"",
      picker_id,
      "-name\">Emoji name</label><div class=\"lab-reaction-custom-row\"><input id=\"",
      picker_id,
      "-name\" name=\"emoji\" type=\"text\" maxlength=\"100\" autocomplete=\"off\" spellcheck=\"false\" placeholder=\"white_check_mark\" aria-describedby=\"",
      picker_id,
      "-error\"><button type=\"submit\" class=\"lab-reaction-add\">Add</button></div><p class=\"lab-reaction-error\" id=\"",
      picker_id,
      "-error\" role=\"alert\" hidden></p></form></div>"
    ]
  end

  defp lab_reaction_picker(_message), do: ""

  defp lab_emoji_glyph(emoji_name) do
    case List.keyfind(@quick_reactions, emoji_name, 0) do
      {_name, glyph} -> glyph
      nil -> ":#{emoji_name}:"
    end
  end

  defp lab_short_digest(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp lab_reaction(reaction) do
    [
      "<span class=\"reaction-chip\" data-reaction-status=\"",
      escape(reaction.status),
      "\" title=\"Ryker reaction · ",
      escape(reaction.status),
      "\">:",
      escape(reaction.emoji_name),
      ":</span>"
    ]
  end

  defp lab_attachment(attachment) do
    details =
      case {attachment.media_type, attachment.bytes} do
        {media_type, bytes} when is_binary(media_type) and is_integer(bytes) ->
          [escape(media_type), " · ", integer(bytes), " bytes"]

        _unavailable ->
          escape(attachment.status)
      end

    chip = [
      "<span class=\"attachment-chip\"><strong>",
      escape(attachment.name),
      "</strong><span>",
      details,
      "</span></span>"
    ]

    case Map.get(attachment, :path) do
      path when is_binary(path) ->
        preview =
          if attachment.media_type in ["image/png", "image/jpeg", "image/webp", "image/gif"] do
            [
              "<img src=\"",
              escape(path),
              "\" alt=\"Generated attachment: ",
              escape(attachment.name),
              "\" loading=\"lazy\">"
            ]
          else
            ""
          end

        ["<a class=\"attachment-download\" href=\"", escape(path), "\">", preview, chip, "</a>"]

      _no_path ->
        chip
    end
  end

  defp lab_card(card) do
    details =
      Enum.map(card.details, fn {label, value} ->
        [
          "<div class=\"lab-card-detail\"><dt>",
          escape(label),
          "</dt><dd>",
          escape(value),
          "</dd></div>"
        ]
      end)

    controls = Map.get(card, :controls, []) |> Enum.map(&lab_card_control/1)

    choices =
      if Enum.any?(Map.get(card, :controls, []), &is_integer(&1.choice_index)) do
        []
      else
        Enum.map(card.choices, fn choice ->
          ["<span class=\"choice-chip\">", escape(choice), "</span>"]
        end)
      end

    [
      "<section class=\"lab-card\" data-record-kind=\"",
      escape(card.kind),
      "\"><div class=\"lab-card-head\"><span>",
      escape(card.label),
      "</span>",
      if(Card.display_status(card),
        do: ["<span class=\"lab-card-status\">", escape(Card.display_status(card)), "</span>"],
        else: ""
      ),
      "</div><h3>",
      escape(card.title),
      "</h3>",
      if(card.summary, do: ["<p>", escape(card.summary), "</p>"], else: ""),
      if(card[:wait_warning],
        do: [
          "<p class=\"action-error\"><strong>Current scheduling status:</strong> ",
          escape(card.wait_warning),
          "</p>"
        ],
        else: ""
      ),
      if(details == [], do: "", else: ["<dl class=\"lab-card-details\">", details, "</dl>"]),
      if(choices == [], do: "", else: ["<div class=\"choice-list\">", choices, "</div>"]),
      if(controls == [],
        do: "",
        else: ["<div class=\"lab-card-actions\">", controls, "</div>"]
      ),
      if(card.url,
        do: [
          "<a class=\"quiet-link\" href=\"",
          escape(card.url),
          "\" rel=\"noreferrer\">Open exact approval</a>"
        ],
        else: ""
      ),
      "</section>"
    ]
  end

  defp lab_card_control(control) do
    if Map.get(control, :method, :post) == :get do
      ["<a class=\"button\" href=\"", escape(control.path), "\">", escape(control.label), "</a>"]
    else
      [
        "<form method=\"post\" action=\"",
        escape(control.path),
        "\"><input type=\"hidden\" name=\"_token\" value=\"",
        escape(control.token),
        "\">",
        if(is_integer(control.choice_index),
          do: [
            "<input type=\"hidden\" name=\"choice_index\" value=\"",
            integer(control.choice_index),
            "\">"
          ],
          else: ""
        ),
        if(is_binary(Map.get(control, :publication_ref)),
          do: [
            "<input type=\"hidden\" name=\"publication_ref\" value=\"",
            escape(control.publication_ref),
            "\">"
          ],
          else: ""
        ),
        "<button type=\"submit\">",
        escape(control.label),
        "</button></form>"
      ]
    end
  end

  defp integer(value) when is_integer(value), do: Integer.to_string(value)
  defp integer(value), do: to_string(value)

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
