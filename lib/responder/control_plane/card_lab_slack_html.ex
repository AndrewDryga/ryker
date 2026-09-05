defmodule Responder.ControlPlane.CardLabSlackHTML do
  alias Responder.ControlPlane.SlackNames
  @moduledoc false

  def panel(snapshot, delivery, token) do
    [
      "<section id=\"slack-delivery\" class=\"card-lab-slack\"><p class=\"eyebrow\">Native rendering</p><h2>Post to Slack</h2>",
      "<p>See the actual Slack rendering. Posts are labelled test content; specimen buttons cannot operate on real work.</p>",
      post_form(snapshot, delivery, token),
      Enum.map(delivery.posts, &post_row(snapshot, &1)),
      "</section>"
    ]
  end

  def confirm(snapshot, target, action, fields, label) do
    [
      "<section class=\"confirm\"><p class=\"eyebrow\">Review Slack destination</p><h2>",
      escape(label),
      "</h2><p><strong>",
      escape(snapshot.card.title),
      " · ",
      escape(snapshot.state.label),
      "</strong></p><p>Workspace <strong>",
      workspace_name(target.workspace_ref),
      "</strong> · Channel <strong>#",
      escape(target.channel_name),
      "</strong> (",
      escape(target.channel_ref),
      ")</p>",
      "<p>This writes test content to the named Slack destination. Controls are isolated from production actions.</p>",
      "<form method=\"post\" action=\"",
      escape(action),
      "\">",
      hidden(fields),
      "<button type=\"submit\">",
      escape(label),
      "</button> <a href=\"",
      path(snapshot),
      "\">Cancel</a></form></section>"
    ]
  end

  defp post_form(_snapshot, %{available: false}, _token),
    do: "<p class=\"empty\">Slack is not configured for this deployment.</p>"

  defp post_form(%{card: %{surface: surface}}, _delivery, _token) when surface != :message,
    do:
      "<p class=\"empty\">This specimen requires its native App Home, modal, or assistant-thread surface. It cannot be posted as a chat message.</p>"

  defp post_form(_snapshot, %{channels: []}, _token),
    do:
      "<p class=\"empty\">Invite Responder to a non-shared test channel in the configured workspace first.</p>"

  defp post_form(snapshot, delivery, token) do
    [
      "<form class=\"card-lab-feedback-form\" method=\"post\" action=\"",
      path(snapshot),
      "/slack/preview\">",
      hidden(%{"_token" => token, "workspace_ref" => delivery.workspace_ref}),
      "<label>Slack channel<input type=\"text\" name=\"channel_ref\" required maxlength=\"100\" placeholder=\"#test or channel ID\" autocomplete=\"off\"></label><small>Workspace ",
      workspace_name(delivery.workspace_ref),
      ". The next step resolves and confirms the channel name.</small><button type=\"submit\">Review Slack post</button></form>"
    ]
  end

  defp post_row(snapshot, post) do
    base = path(snapshot) <> "/slack/" <> URI.encode(post.id, &URI.char_unreserved?/1)

    [
      "<article class=\"card-lab-post\"><strong>#",
      escape(post.channel_name),
      "</strong><p>",
      escape(post.state_id),
      " · ",
      escape(post.status),
      " · revision ",
      escape(post.revision),
      "</p>",
      link(post),
      if(post.last_error, do: ["<p role=\"status\">", escape(post.last_error), "</p>"], else: []),
      "<p><a href=\"",
      base,
      "/update\">Update this Slack message to ",
      escape(snapshot.state.label),
      "</a></p>",
      if(post.status in [:blocked, :pending],
        do: ["<a href=\"", base, "/retry\">Review retry</a>"],
        else: []
      ),
      "</article>"
    ]
  end

  defp link(%{message_ref: nil}), do: "<p class=\"muted\">Awaiting a confirmed Slack receipt.</p>"

  defp link(post) do
    [
      "<a target=\"_blank\" rel=\"noreferrer noopener\" href=\"https://slack.com/archives/",
      URI.encode(post.channel_ref, &URI.char_unreserved?/1),
      "/p",
      URI.encode(String.replace(post.message_ref, ".", ""), &URI.char_unreserved?/1),
      "\">Open message in Slack ↗</a>"
    ]
  end

  defp hidden(fields) do
    Enum.map(fields, fn {key, value} ->
      ["<input type=\"hidden\" name=\"", escape(key), "\" value=\"", escape(value), "\">"]
    end)
  end

  defp workspace_name(ref),
    do: [
      "<span title=\"",
      escape(ref),
      "\">",
      escape(SlackNames.name(ref, ref)),
      "</span>"
    ]

  defp path(snapshot),
    do:
      "/card-lab/" <>
        URI.encode(snapshot.card.id, &URI.char_unreserved?/1) <>
        "/" <> URI.encode(snapshot.state.id, &URI.char_unreserved?/1)

  defp escape(nil), do: ""
  defp escape(value), do: value |> to_string() |> Plug.HTML.html_escape()
end
