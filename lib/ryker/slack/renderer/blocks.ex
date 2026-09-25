defmodule Ryker.Slack.Renderer.Blocks do
  @moduledoc """
  The Block Kit vocabulary every Slack card is built from.

  Builders return the exact map Slack accepts; text helpers escape control
  syntax, bound section length and format host-owned dates. Cards import this
  module so a correction to a heading, a button or an escape rule lands on
  every card at once.
  """

  alias Ryker.Slack.Renderer.Fields

  @maximum_section_characters 3_000
  @maximum_markdown_characters 12_000
  @maximum_button_characters 75

  @doc "Slack's bound on a button label; longer choices are numbered instead."
  @spec maximum_button_characters() :: pos_integer()
  def maximum_button_characters, do: @maximum_button_characters

  # --- text ---------------------------------------------------------------

  # Slack reads `<`, `>` and `&` as control syntax in mrkdwn and in plain
  # notification text alike; every value the host did not assemble from
  # validated refs goes through here so it can never become a mention, a link
  # or a date token.
  def escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  def truncate(text, maximum) do
    graphemes = String.graphemes(text)

    if length(graphemes) <= maximum,
      do: text,
      else: graphemes |> Enum.take(maximum - 1) |> Enum.join() |> Kernel.<>("…")
  end

  # All owned structural headings share one colonless renderer.
  def heading(label), do: label |> String.trim() |> String.trim_trailing(":")

  def compact_lines(lines), do: lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")

  def plural(1, singular, _plural), do: singular
  def plural(_count, _singular, plural), do: plural

  def display_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> Calendar.strftime(at, "%d %b, %H:%M UTC")
      _ -> escape(value)
    end
  end

  def slack_date(value) do
    {:ok, at, 0} = DateTime.from_iso8601(value)
    fallback = Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
    "<!date^#{DateTime.to_unix(at)}^{date_short_pretty} at {time}|#{fallback}>"
  end

  def mention(user_ref), do: "<@#{user_ref}>"
  def group_mention(group_ref), do: "<!subteam^#{group_ref}>"

  def channel_mention(channel_ref) do
    if Fields.slack_reference?(channel_ref),
      do: "<##{channel_ref}>",
      else: "`#{escape(channel_ref)}`"
  end

  # A link's destination and label are separate values the host validated. Both
  # are escaped, and a `|` in the label stays part of the label.
  def link(url, label),
    do: "<#{escape(url)}|#{label |> escape() |> String.replace("|", "&#124;")}>"

  # A repository is a typed link. Ordinary text is escaped and never becomes
  # clickable Slack markup.
  def repository_link(%{"ref" => ref, "url" => nil}), do: "`#{escape(ref)}`"
  def repository_link(%{"ref" => ref, "url" => url}), do: link(url, ref)

  # --- blocks -------------------------------------------------------------

  def section(text) do
    %{
      "text" => %{"text" => truncate(text, @maximum_section_characters), "type" => "mrkdwn"},
      "type" => "section"
    }
  end

  def context(text),
    do: %{"type" => "context", "elements" => [%{"type" => "mrkdwn", "text" => text}]}

  def actions(ref, buttons) when is_list(buttons) do
    %{
      "block_id" => ref,
      "elements" => buttons,
      "type" => "actions"
    }
  end

  def actions(ref, button), do: actions(ref, [button])

  def fact_fields(facts) do
    %{
      "fields" =>
        Enum.map(facts, fn {label, value} ->
          %{"text" => "*#{heading(label)}*\n#{fact_markdown(value)}", "type" => "mrkdwn"}
        end),
      "type" => "section"
    }
  end

  # Fact values are escaped text unless the host typed them: a repository link,
  # a channel reference, or markup it assembled itself from validated refs.
  defp fact_markdown(values) when is_list(values),
    do: Enum.map_join(values, "\n", &fact_markdown/1)

  defp fact_markdown(%{"ref" => _ref} = repository), do: repository_link(repository)

  defp fact_markdown({:repository, repository, role}),
    do: repository_link(repository) <> " — " <> escape(role)

  defp fact_markdown(%{"channel_ref" => channel_ref}), do: channel_mention(channel_ref)
  defp fact_markdown({:markup, text}), do: text
  defp fact_markdown(value), do: escape(value)

  # The same facts as notification text, where markup is noise.
  def fact_text(values) when is_list(values), do: Enum.map_join(values, ", ", &fact_text/1)
  def fact_text(%{"ref" => ref}), do: escape(ref)
  def fact_text({:repository, %{"ref" => ref}, role}), do: escape(ref) <> " — " <> escape(role)
  def fact_text(%{"channel_ref" => channel_ref}), do: channel_mention(channel_ref)
  def fact_text({:markup, text}), do: text
  def fact_text(value), do: escape(value)

  def code_block(text) do
    %{
      "type" => "rich_text",
      "elements" => [
        %{
          "type" => "rich_text_preformatted",
          "elements" => [
            %{"type" => "text", "text" => truncate(text, @maximum_section_characters)}
          ]
        }
      ]
    }
  end

  # Model prose goes through Slack's `markdown` block while it fits Slack's
  # cumulative Markdown bound; oversized prose stays complete in inert
  # plain-text sections.
  def message_blocks(text) do
    if String.length(text) <= @maximum_markdown_characters do
      [%{"text" => text, "type" => "markdown"}]
    else
      plain_message_blocks(text)
    end
  end

  def plain_message_blocks(text) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(@maximum_section_characters)
    |> Enum.map(fn graphemes ->
      %{
        "text" => plain_text(Enum.join(graphemes)),
        "type" => "section"
      }
    end)
  end

  # --- elements -----------------------------------------------------------

  def plain_text(text), do: %{"emoji" => true, "text" => text, "type" => "plain_text"}

  def button(action_id, label, value, style, title, confirmation, confirm_label) do
    %{
      "action_id" => action_id,
      "confirm" => %{
        "confirm" => plain_text(confirm_label),
        "deny" => plain_text("Cancel"),
        "text" => plain_text(confirmation),
        "title" => plain_text(title)
      },
      "text" => plain_text(label),
      "type" => "button",
      "value" => value
    }
    |> maybe_button_style(style)
  end

  def plain_button(action_id, label, value) do
    %{
      "action_id" => action_id,
      "text" => plain_text(label),
      "type" => "button",
      "value" => value
    }
  end

  def url_button(action_id, label, value, url) do
    %{
      "action_id" => action_id,
      "text" => plain_text(label),
      "type" => "button",
      "url" => url,
      "value" => value
    }
  end

  def maybe_button_style(button, nil), do: button
  def maybe_button_style(button, style), do: Map.put(button, "style", style)
end
