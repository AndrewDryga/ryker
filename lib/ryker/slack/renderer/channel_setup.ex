defmodule Ryker.Slack.Renderer.ChannelSetup do
  @moduledoc """
  The optional setup Q&A: one message that replaces itself after every step
  and explains each option before asking for a choice.
  """

  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields

  alias Ryker.Slack.Renderer.ChannelCards

  @setup_statuses ~w(asking confirming saved cancelled expired)
  @setup_steps ~w(participation environment alerts audience confirm)
  # Environment choices wrap into rows of this many buttons.
  @environment_buttons_per_row 5
  @maximum_environment_options 200

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
         :ok <- iso8601(expires_at),
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
         "environment",
         %{"environment_options" => environments},
         session_ref,
         _presentation
       )
       when is_list(environments) and length(environments) <= @maximum_environment_options do
    if Enum.all?(environments, &environment_option?/1),
      do: environment_step(environments, session_ref),
      else: {:error, {:invalid_slack_render, :channel_setup}}
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
    if setup_draft?(draft),
      do: setup_confirmation(draft, session_ref, presentation),
      else: {:error, {:invalid_slack_render, :channel_setup}}
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

  # Each environment says what work in this channel could use there before it
  # is chosen; No environment is always offered, even when there are none.
  defp environment_step(environments, session_ref) do
    buttons =
      environments
      |> Enum.with_index()
      |> Enum.map(fn {environment, index} ->
        setup_button(
          "ryker_setup_environment_#{index}",
          truncate(environment["name"], maximum_button_characters()),
          session_ref,
          nil
        )
      end)
      |> Kernel.++([
        setup_button("ryker_setup_environment_none", "No environment", session_ref, nil)
      ])

    text = "Which environment should I work in here?"

    explanation =
      [
        "*#{heading("2 · Environment")}*",
        text,
        ""
      ] ++
        Enum.flat_map(environments, fn environment ->
          ["*#{escape(environment["name"])}* — #{environment_sentence(environment)}", ""]
        end) ++
        [
          "*No environment* — I'll still answer here, but without any repos or Emisar.",
          "",
          "Environments are set up in Ryker's settings. Choosing one only decides which one this channel uses; it doesn't change what's in it."
        ]

    {:ok, [section(Enum.join(explanation, "\n"))] ++ setup_action_groups(session_ref, buttons),
     text}
  end

  defp environment_sentence(%{"repositories" => [], "emisar" => true}),
    do: "I'll use Emisar, but there are no repos in it to work on."

  defp environment_sentence(%{"repositories" => []}),
    do: "It has no repos or Emisar, so I'll answer without them."

  defp environment_sentence(%{"repositories" => [writable | read_only], "emisar" => emisar}) do
    reads =
      if read_only == [], do: [], else: ["read #{read_only |> Enum.map(&code/1) |> names()}"]

    emisar = if emisar, do: ["use Emisar"], else: []

    "I'll #{clauses(["make changes in #{code(writable)}"] ++ reads ++ emisar)}."
  end

  defp code(ref), do: "`#{escape(ref)}`"

  defp names([name]), do: name

  defp names(names) do
    {others, [last]} = Enum.split(names, -1)
    Enum.join(others, ", ") <> " and " <> last
  end

  defp clauses([clause]), do: clause
  defp clauses([first, second]), do: "#{first} and #{second}"

  defp clauses(clauses) do
    {others, [last]} = Enum.split(clauses, -1)
    Enum.join(others, ", ") <> ", and " <> last
  end

  defp setup_confirmation(draft, session_ref, presentation) do
    text = "Here's how I'll work in this channel:"

    summary =
      [
        "*#{heading("5 · Confirm")}*",
        text,
        "• " <> draft_participation_sentence(draft["participation"], presentation.bot_user_ref),
        "• " <> draft_alert_sentence(draft["alert_policy"]),
        "• " <> draft_environment_sentence(draft),
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

  defp draft_environment_sentence(%{"environment_ref" => nil}),
    do: "I won't use an environment, so I'll answer without any repos or Emisar."

  defp draft_environment_sentence(%{"environment_ref" => ref, "environment_options" => options}) do
    %{"name" => name} = Enum.find(options, &(&1["ref"] == ref))
    "I'll work in the *#{escape(name)}* environment."
  end

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
      chosen_environment?(draft) and
      is_list(draft["invite_user_refs"]) and is_list(draft["invite_user_group_refs"]) and
      Enum.all?(draft["invite_user_refs"] ++ draft["invite_user_group_refs"], &slack_reference?/1)
  end

  # Answered, as one of the environments offered or as No environment (nil).
  defp chosen_environment?(%{"environment_ref" => nil}), do: true

  defp chosen_environment?(%{"environment_ref" => ref, "environment_options" => options})
       when is_binary(ref) and is_list(options),
       do: Enum.any?(options, &(environment_option?(&1) and &1["ref"] == ref))

  defp chosen_environment?(_draft), do: false

  defp environment_option?(
         %{"emisar" => emisar, "name" => name, "ref" => ref, "repositories" => repositories} =
           option
       )
       when map_size(option) == 4 and is_boolean(emisar) and is_list(repositories),
       do: text?(name) and text?(ref) and Enum.all?(repositories, &text?/1)

  defp environment_option?(_option), do: false

  defp setup_action_groups(session_ref, buttons) do
    buttons
    |> Enum.chunk_every(@environment_buttons_per_row)
    |> Enum.with_index()
    |> Enum.map(fn {group, index} -> actions("setup:#{session_ref}:#{index}", group) end)
  end

  defp setup_button(action_id, label, session_ref, style) do
    action_id
    |> plain_button(label, session_ref)
    |> maybe_button_style(style)
  end
end
