defmodule Ryker.Slack.Renderer.ChannelSetup do
  @moduledoc """
  The optional setup Q&A: one message that replaces itself after every step
  and explains each option before asking for a choice.
  """

  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields

  alias Ryker.Slack.Renderer.ChannelCards

  @setup_statuses ~w(asking confirming saved cancelled expired)
  @setup_steps ~w(participation repository alerts audience confirm)

  @spec render(map()) :: {:ok, map()} | {:error, term()}
  def render(
        %{
          "bot_user_ref" => bot_user_ref,
          "draft" => draft,
          "expires_at" => expires_at,
          "revision" => revision,
          "session_ref" => session_ref,
          "status" => status,
          "step" => step
        } = setup
      )
      when map_size(setup) == 7 and status in @setup_statuses and step in @setup_steps and
             is_integer(revision) and revision > 0 and is_map(draft) do
    with :ok <- slack_user(bot_user_ref),
         {:ok, _uuid} <- Ecto.UUID.cast(session_ref),
         {:ok, _datetime, 0} <- DateTime.from_iso8601(expires_at),
         {:ok, blocks, text} <-
           setup_blocks(status, step, draft, session_ref, %{
             bot_user_ref: bot_user_ref,
             expires_at: expires_at
           }) do
      {:ok, %{"blocks" => blocks, "text" => text}}
    else
      _invalid -> {:error, {:invalid_slack_render, :channel_setup}}
    end
  end

  def render(_setup), do: {:error, {:invalid_slack_render, :channel_setup}}

  # Every step explains each option before asking for a choice. The bold label
  # is the exact button label; the sentence says what Ryker will do.
  defp setup_blocks("asking", "participation", _draft, session_ref, presentation) do
    text = "When should I join conversations?"

    explanation =
      [
        "*#{heading("1 · Conversations")}*",
        text,
        "",
        "*Mentions only* — I'll read along to learn about your team's work, but I'll only join a conversation when you mention #{mention(presentation.bot_user_ref)}.",
        "",
        "*Be proactive* — I'll read the messages in this channel and join in when I think you could use my help. You can still mention me whenever you need me.",
        "",
        "*Observe only* — I'll keep reading and learning, but I won't reply, even if you mention me. I also won't start alert investigations while this is on."
      ]
      |> Enum.join("\n")

    {:ok,
     [
       section(explanation),
       actions("setup:#{session_ref}", [
         setup_button(
           "ryker_setup_participation_mentions",
           "Mentions only",
           session_ref,
           nil
         ),
         setup_button(
           "ryker_setup_participation_proactive",
           "Be proactive",
           session_ref,
           nil
         ),
         setup_button("ryker_setup_participation_shadow", "Observe only", session_ref, nil)
       ])
     ], text}
  end

  defp setup_blocks(
         "asking",
         "repository",
         %{"repository_options" => repositories},
         session_ref,
         _presentation
       )
       when is_list(repositories) and length(repositories) in 1..32 do
    buttons =
      repositories
      |> Enum.with_index()
      |> Enum.map(fn {repository, index} ->
        setup_button(
          "ryker_setup_repository_#{index}",
          truncate(repository, maximum_button_characters()),
          session_ref,
          nil
        )
      end)

    text = "Which repo should I use for coding tasks when you don't name one?"

    explanation =
      [
        "*#{heading("2 · Repositories")}*",
        text,
        "",
        Enum.map_join(repositories, "   ", &"*#{escape(&1)}*"),
        "",
        "You can still ask me to work in any other connected repo. This only sets the default; it doesn't give me access to anything new."
      ]

    {:ok, [section(Enum.join(explanation, "\n"))] ++ setup_action_groups(session_ref, buttons),
     text}
  end

  defp setup_blocks("asking", "alerts", _draft, session_ref, _presentation) do
    text = "When an alert needs attention, should I open an incident room for it?"

    explanation =
      [
        "*#{heading("3 · Alerts")}*",
        text,
        "",
        "*Investigate here* — I'll look into it in the alert's own thread and share what I find. This is the default.",
        "",
        "*Offer a room* — I'll start in the thread, and offer a room when the alert looks big enough to need one.",
        "",
        "*Always open a room* — every alert I investigate gets its own room, and I'll work there."
      ]
      |> Enum.join("\n")

    {:ok,
     [
       section(explanation),
       actions("setup:#{session_ref}", [
         setup_button("ryker_setup_alerts_reply", "Investigate here", session_ref, nil),
         setup_button("ryker_setup_alerts_offer", "Offer a room", session_ref, nil),
         setup_button(
           "ryker_setup_alerts_automatic",
           "Always open a room",
           session_ref,
           "danger"
         )
       ])
     ], text}
  end

  defp setup_blocks("asking", "audience", _draft, session_ref, _presentation) do
    text = "Who should I invite when I open an incident room?"

    explanation =
      [
        "*#{heading("4 · Invitations")}*",
        text,
        "",
        "Reply in this thread with the people or user groups you want in the room, as @mentions. I'll remember them for the next one in this channel, and you can change them any time.",
        "",
        "If you'd rather invite people yourself each time, choose *Nobody automatically*."
      ]
      |> Enum.join("\n")

    {:ok,
     [
       section(explanation),
       actions(
         "setup:#{session_ref}",
         setup_button("ryker_setup_audience_none", "Nobody automatically", session_ref, nil)
       )
     ], text}
  end

  defp setup_blocks("confirming", "confirm", draft, session_ref, presentation) do
    case setup_draft?(draft) do
      true -> setup_confirmation(draft, session_ref, presentation)
      false -> {:error, {:invalid_slack_render, :channel_setup}}
    end
  end

  defp setup_blocks("saved", _step, _draft, _session_ref, _presentation),
    do:
      {:ok, [section("*Settings saved.* I've updated my welcome message to match.")],
       "Settings saved. I've updated my welcome message to match."}

  defp setup_blocks("cancelled", _step, _draft, _session_ref, _presentation),
    do:
      {:ok, [section("*Setup cancelled.* Your settings haven't changed.")],
       "Setup cancelled. Your settings haven't changed."}

  defp setup_blocks("expired", _step, _draft, _session_ref, _presentation),
    do:
      {:ok,
       [
         section(
           "*Setup expired.* Your settings haven't changed. Use *Customize* on my welcome message to start again."
         )
       ], "Setup expired. Your settings haven't changed."}

  defp setup_blocks(_status, _step, _draft, _session_ref, _presentation),
    do: {:error, {:invalid_slack_render, :channel_setup}}

  defp setup_confirmation(draft, session_ref, presentation) do
    text = "Here's how I'll work in this channel:"

    summary =
      [
        "*#{heading("5 · Confirm")}*",
        text,
        "• " <> draft_participation_sentence(draft["participation"], presentation.bot_user_ref),
        "• " <> draft_alert_sentence(draft["alert_policy"]),
        "• I'll use *#{escape(draft["repository_ref"])}* for coding tasks when you don't name a repo.",
        "• If I create an incident room, I'll invite #{draft_audience_phrase(draft)}.",
        "",
        "*Save settings* — I'll start using these choices and update my welcome message to match.",
        "",
        "*Start over* — Go back to the first question and change your choices before saving.",
        "",
        "*Cancel* — I'll leave your current settings as they are."
      ]
      |> Enum.join("\n")

    {:ok,
     [
       section(summary),
       actions("setup:#{session_ref}", [
         setup_button("ryker_setup_save", "Save settings", session_ref, "primary"),
         setup_button("ryker_setup_restart", "Start over", session_ref, nil),
         setup_button("ryker_setup_cancel", "Cancel", session_ref, "danger")
       ])
     ], text}
  end

  defp draft_participation_sentence("mentions", bot_user_ref),
    do: "I'll reply when you mention #{mention(bot_user_ref)}."

  defp draft_participation_sentence("proactive", _bot_user_ref),
    do: "I'll join conversations when I think you could use my help."

  defp draft_participation_sentence("shadow", _bot_user_ref),
    do: "I'll observe without replying or starting alert investigations."

  defp draft_alert_sentence("reply"),
    do: "When an alert needs investigation, I'll work in its thread."

  defp draft_alert_sentence("offer"),
    do:
      "When an alert needs investigation, I'll ask whether to work in its thread or create an incident room."

  defp draft_alert_sentence("automatic"),
    do: "When an alert needs investigation, I'll create an incident room automatically."

  defp draft_audience_phrase(draft) do
    ChannelCards.audience_phrase(%{
      "invitations" => %{
        "user_group_refs" => draft["invite_user_group_refs"],
        "user_refs" => draft["invite_user_refs"]
      }
    })
  end

  defp setup_draft?(draft) do
    draft["participation"] in ~w(mentions proactive shadow) and
      draft["alert_policy"] in ~w(reply offer automatic) and
      is_binary(draft["repository_ref"]) and draft["repository_ref"] != "" and
      is_list(draft["invite_user_refs"]) and is_list(draft["invite_user_group_refs"]) and
      Enum.all?(draft["invite_user_refs"] ++ draft["invite_user_group_refs"], &slack_reference?/1)
  end

  defp setup_action_groups(session_ref, buttons) do
    buttons
    |> Enum.chunk_every(5)
    |> Enum.with_index()
    |> Enum.map(fn {group, index} -> actions("setup:#{session_ref}:#{index}", group) end)
  end

  defp setup_button(action_id, label, session_ref, style) do
    %{
      "action_id" => action_id,
      "text" => plain_text(label),
      "type" => "button",
      "value" => session_ref
    }
    |> maybe_button_style(style)
  end
end
