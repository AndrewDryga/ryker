defmodule Ryker.Slack.Renderer.ChannelCards do
  @moduledoc """
  The welcome and the settings view, generated from one effective-settings
  projection so the hello, the post-Q&A re-render and settings on request can
  never disagree about what Ryker does in a channel.
  """

  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields

  @greeting "Hey there, I'm your AI teammate. I'm here to help with work in this channel."
  @settings_sources ~w(channel incident_room installation)

  @spec welcome(map()) :: {:ok, map()} | {:error, term()}
  def welcome(
        %{
          "bot_user_ref" => bot_user_ref,
          "configuration_ref" => configuration_ref,
          "notice" => notice,
          "revision" => revision,
          "settings" => settings
        } = welcome
      )
      when map_size(welcome) == 5 and is_integer(revision) and revision > 0 do
    with {:ok, _uuid} <- Ecto.UUID.cast(configuration_ref),
         :ok <- slack_user(bot_user_ref),
         :ok <- optional_notice(notice),
         :ok <- channel_settings(settings) do
      paragraphs = welcome_paragraphs(settings, bot_user_ref, notice)
      value = "#{configuration_ref}|#{revision}"

      blocks =
        Enum.map(paragraphs, &section/1) ++
          [actions("welcome:#{configuration_ref}", welcome_buttons(settings, value))]

      {:ok, %{"blocks" => blocks, "text" => welcome_text(settings, notice)}}
    else
      _invalid -> {:error, {:invalid_slack_render, :channel_welcome}}
    end
  end

  def welcome(_welcome), do: {:error, {:invalid_slack_render, :channel_welcome}}

  @spec settings(map()) :: {:ok, map()} | {:error, term()}
  def settings(
        %{
          "audience" => audience,
          "bot_user_ref" => bot_user_ref,
          "configuration_ref" => configuration_ref,
          "revision" => revision,
          "settings" => settings
        } = view
      )
      when map_size(view) == 5 and audience in ~w(private thread) do
    with :ok <- slack_user(bot_user_ref),
         :ok <- optional_configuration_identity(configuration_ref, revision),
         :ok <- channel_settings(settings) do
      facts = settings_facts(settings)

      blocks =
        [section("*#{heading("Channel settings")}*"), fact_fields(facts)] ++
          settings_context(settings) ++
          settings_controls(audience, configuration_ref, revision)

      text =
        Enum.map_join(facts, "\n", fn {label, value} ->
          "#{heading(label)}: #{fact_text(value)}"
        end)

      {:ok, %{"blocks" => blocks, "text" => "Channel settings\n" <> text}}
    else
      _invalid -> {:error, {:invalid_slack_render, :channel_settings}}
    end
  end

  def settings(_view), do: {:error, {:invalid_slack_render, :channel_settings}}

  defp welcome_paragraphs(settings, bot_user_ref, notice) do
    [
      @greeting,
      environment_access(settings),
      "*#{heading("How to work with me")}*\n" <>
        conversation_sentence(settings, bot_user_ref) <>
        "\n\n" <> alert_sentence(settings),
      "*#{heading("What I can help with")}*\n" <>
        "• *Tasks* — “Add per-worker memory metrics to the website.” I'll plan the work, implement it, run checks and open a draft PR.\n" <>
        "• *Scheduled tasks* — “Check our infrastructure every morning and flag any issues.”\n" <>
        "• *Standing rules* — “Review new Terraform deployments, summarize the plan and release changes, and watch applies for failures.”",
      welcome_closing(settings, notice)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp welcome_text(settings, notice) do
    [
      @greeting,
      participation_summary(settings),
      alert_summary(settings),
      notice_fallback(notice)
    ]
    |> compact_lines()
  end

  # The channel's environment decides what its work may use: the repo work
  # changes, the ones it only reads, and Emisar. No environment means none of
  # them, which is never the same as the default.
  defp environment_access(%{"environment" => nil, "environment_count" => 0}),
    do:
      "I don't have access to any repos, so please connect one (or more) if you want me to work on coding tasks."

  defp environment_access(%{"environment" => nil} = settings),
    do:
      "This channel doesn't use an environment, so I'll answer here without any repos or Emisar. Choose one with *#{configure_label(settings)}* if you want me to work on code here."

  defp environment_access(%{"environment" => %{"ready" => false, "ref" => ref}}),
    do:
      "This channel uses the `#{escape(ref)}` environment, but it can't run work right now, so I'll answer without any repos or Emisar until it can."

  defp environment_access(%{
         "environment" => %{"emisar" => emisar, "name" => name, "repositories" => []}
       }) do
    emisar = if emisar, do: ", but I can use Emisar", else: ""

    "I work in the *#{escape(name)}* environment here. It has no repos, so I won't work on coding tasks in this channel#{emisar}."
  end

  defp environment_access(%{
         "environment" => %{
           "emisar" => emisar,
           "name" => name,
           "repositories" => [writable | read_only]
         }
       }) do
    reads =
      if read_only == [],
        do: [],
        else: ["read #{read_only |> Enum.map(&repository_link/1) |> join_names()}"]

    emisar = if emisar, do: ["use Emisar"], else: []
    uses = join_clauses(["make changes in #{repository_link(writable)}"] ++ reads ++ emisar)

    "I work in the *#{escape(name)}* environment here: I can #{uses}."
  end

  defp join_clauses([clause]), do: clause
  defp join_clauses([first, second]), do: "#{first} and #{second}"

  defp join_clauses(clauses) do
    {others, [last]} = Enum.split(clauses, -1)
    Enum.join(others, ", ") <> ", and " <> last
  end

  # The control that opens the setup Q&A, named as the welcome shows it.
  defp configure_label(%{"participation" => %{"source" => "incident_room"}}),
    do: "Configure channel"

  defp configure_label(%{"participation" => %{"value" => "shadow"}}), do: "Configure channel"
  defp configure_label(_settings), do: "Customize"

  defp conversation_sentence(%{"observation" => %{"on" => true}}, bot_user_ref),
    do:
      "I'm watching quietly for now — reading along to learn how this channel works, and staying out of the conversation. Mention #{mention(bot_user_ref)} whenever you want me in it."

  defp conversation_sentence(%{"participation" => %{"value" => "proactive"}}, bot_user_ref),
    do:
      "Talk to me like any other teammate. I'll read the messages I can access here to build useful knowledge and join conversations when I can help. You can also mention #{mention(bot_user_ref)} directly."

  defp conversation_sentence(_settings, bot_user_ref),
    do:
      "Talk to me like any other teammate. I'll read the messages I can access here to build useful knowledge. In conversations, I'll reply when you mention #{mention(bot_user_ref)}."

  defp alert_sentence(%{"observation" => %{"on" => true}}),
    do:
      "Alerts posted here go into that reading too, and I'll wait to be asked before looking into one."

  defp alert_sentence(%{"alert_policy" => "reply"}),
    do:
      "When an alert is posted here, I'll investigate proactively in its thread and share what I find."

  defp alert_sentence(%{"alert_policy" => "offer"} = settings),
    do:
      "When an alert needs investigation, I'll offer to investigate in its thread or create a dedicated incident room. If you choose a room, I'll invite #{audience_phrase(settings)}."

  defp alert_sentence(%{"alert_policy" => "automatic"} = settings),
    do:
      "When an alert needs investigation, I'll automatically create an incident room and invite #{audience_phrase(settings)}."

  defp welcome_closing(settings, notice) do
    [override_sentence(settings), notice_line(notice)] |> compact_lines()
  end

  # The fallback line is read aloud and shown in notifications, where a mention
  # is noise rather than a link.
  defp notice_fallback(nil), do: nil

  defp notice_fallback(%{"at" => at}) do
    {:ok, changed_at, 0} = DateTime.from_iso8601(at)
    "Settings changed at #{Calendar.strftime(changed_at, "%H:%M UTC")}."
  end

  defp notice_fallback(notice), do: escape(notice)

  defp notice_line(nil),
    do: "You're ready to go. Use the buttons below if you'd like to change how I work."

  defp notice_line(%{"actor_ref" => actor, "at" => at}) do
    {:ok, changed_at, 0} = DateTime.from_iso8601(at)
    "*Settings changed by #{mention(actor)} at #{Calendar.strftime(changed_at, "%H:%M UTC")}*"
  end

  defp notice_line(notice), do: "*#{escape(notice)}*"

  defp override_sentence(%{"participation" => %{"source" => "channel", "value" => setting}})
       when setting in ~w(proactive shadow),
       do:
         "This channel has its own `#{setting}` setting, so it no longer follows the installation default. `/ryker #{setting} inherit` returns it to the default."

  defp override_sentence(_settings), do: nil

  defp welcome_buttons(%{"participation" => %{"source" => "incident_room"}}, value),
    do: [plain_button("ryker_welcome_configure", "Configure channel", value)]

  defp welcome_buttons(%{"participation" => %{"value" => "shadow"}}, value),
    do: [plain_button("ryker_welcome_configure", "Configure channel", value)]

  defp welcome_buttons(%{"participation" => %{"value" => "proactive"}}, value),
    do: [
      plain_button("ryker_welcome_mentions_only", "Mentions only", value),
      plain_button("ryker_welcome_configure", "Customize", value)
    ]

  defp welcome_buttons(_settings, value),
    do: [
      "ryker_welcome_be_proactive"
      |> plain_button("Be proactive", value)
      |> maybe_button_style("primary"),
      plain_button("ryker_welcome_configure", "Customize", value)
    ]

  defp settings_facts(settings) do
    [
      {"Conversations", participation_summary(settings)},
      {"Alerts", alert_summary(settings)},
      {"Environment", environment_fact(settings)},
      {"Repositories", repositories_fact(settings)},
      {"Incident invitations", {:markup, String.capitalize(audience_phrase(settings))}},
      {"Observation mode", observation_fact(settings)}
    ]
  end

  defp participation_summary(%{"observation" => %{"on" => true}}), do: "Observe without replying"

  defp participation_summary(%{"participation" => %{"value" => "proactive"}}),
    do: "Join when useful"

  defp participation_summary(_settings), do: "Reply when mentioned"

  defp alert_summary(%{"observation" => %{"on" => true}}), do: "No proactive investigations"
  defp alert_summary(%{"alert_policy" => "reply"}), do: "Investigate in the existing thread"
  defp alert_summary(%{"alert_policy" => "offer"}), do: "Offer an in-place task or incident room"

  defp alert_summary(%{"alert_policy" => "automatic"}),
    do: "Create an incident room automatically"

  defp environment_fact(%{"environment" => nil}), do: "No environment"

  defp environment_fact(%{"environment" => %{"ready" => false, "ref" => ref}}),
    do: "#{ref} (can't run work right now)"

  defp environment_fact(%{"environment" => %{"emisar" => true, "name" => name}}),
    do: "#{name}, with Emisar"

  defp environment_fact(%{"environment" => %{"name" => name}}), do: name

  # The repo work changes comes first; the rest are only read.
  defp repositories_fact(%{"environment" => %{"repositories" => [writable | read_only]}}),
    do: [
      {:repository, writable, "changes"}
      | Enum.map(read_only, &{:repository, &1, "read only"})
    ]

  defp repositories_fact(_settings), do: "None"

  defp observation_fact(%{"observation" => %{"on" => true, "source" => "incident_room"}}),
    do: "On (incident room)"

  defp observation_fact(%{"observation" => %{"on" => true}}), do: "On"
  defp observation_fact(_settings), do: "Off"

  @doc "Who an incident room invites, as mentions or the explanation that nobody is invited automatically."
  @spec audience_phrase(map()) :: String.t()
  def audience_phrase(%{"invitations" => invitations}) do
    chosen =
      Enum.map(invitations["user_refs"], &mention/1) ++
        Enum.map(invitations["user_group_refs"], &group_mention/1)

    case chosen do
      [] -> "no one automatically — you can add people yourself"
      chosen -> join_names(chosen)
    end
  end

  defp join_names([name]), do: name

  defp join_names(names) do
    {head, [last]} = Enum.split(names, -1)
    Enum.join(head, ", ") <> " and " <> last
  end

  defp settings_context(settings) do
    origin =
      case settings do
        %{"participation" => %{"source" => "channel"}, "customized_by" => nil} ->
          "a `/ryker` setting saved for this channel"

        %{"participation" => %{"source" => "incident_room"}} ->
          "this is an incident room"

        %{"customized_by" => nil} ->
          "defaults; nobody has customized this channel yet"

        %{"customized_by" => actor_ref} ->
          customized_by(actor_ref)
      end

    [context("Effective settings · #{origin}")]
  end

  # A Slack member is named; a change made on the channel page on the web has
  # no Slack member to mention, so it says where it was made instead.
  defp customized_by(actor_ref) do
    if slack_reference?(actor_ref),
      do: "saved by #{mention(actor_ref)}",
      else: "changed in Ryker's settings"
  end

  defp settings_controls(_audience, nil, _revision), do: []

  # The private command reply can only carry Configure channel: list controls
  # post cards into a thread, and an ephemeral reply has no thread to post in.
  defp settings_controls(audience, configuration_ref, revision) do
    value = "#{configuration_ref}|#{revision}"

    lists =
      if audience == "thread",
        do: [
          plain_button("ryker_welcome_view_schedules", "View schedules", value),
          plain_button("ryker_welcome_view_rules", "View standing rules", value)
        ],
        else: []

    [
      actions("settings:#{configuration_ref}", [
        "ryker_welcome_configure"
        |> plain_button("Configure channel", value)
        |> maybe_button_style("primary")
        | lists
      ])
    ]
  end

  defp channel_settings(
         %{
           "alert_policy" => alert_policy,
           "configuration_ref" => configuration_ref,
           "customized_by" => customized_by,
           "environment" => environment,
           "environment_count" => environment_count,
           "invitations" => invitations,
           "observation" => observation,
           "participation" => participation,
           "revision" => revision
         } = settings
       )
       when map_size(settings) == 9 do
    valid =
      Enum.all?([
        alert_policy in ~w(reply offer automatic),
        settings_participation?(participation),
        settings_observation?(observation),
        settings_invitations?(invitations),
        settings_environment?(environment),
        is_integer(environment_count) and environment_count >= 0,
        is_nil(customized_by) or bounded_text(customized_by, 256) == :ok,
        optional_configuration_identity(configuration_ref, revision) == :ok
      ])

    if valid, do: :ok, else: {:error, :invalid_channel_settings}
  end

  defp channel_settings(_settings), do: {:error, :invalid_channel_settings}

  defp settings_participation?(%{"source" => source, "value" => value} = participation)
       when map_size(participation) == 2,
       do: source in @settings_sources and value in ~w(mentions proactive shadow)

  defp settings_participation?(_participation), do: false

  defp settings_observation?(%{"on" => on, "source" => source} = observation)
       when map_size(observation) == 2,
       do: is_boolean(on) and source in @settings_sources

  defp settings_observation?(_observation), do: false

  defp settings_invitations?(%{"user_group_refs" => groups, "user_refs" => users} = invitations)
       when map_size(invitations) == 2 and is_list(groups) and is_list(users),
       do: Enum.all?(users ++ groups, &slack_reference?/1)

  defp settings_invitations?(_invitations), do: false

  defp settings_environment?(nil), do: true

  defp settings_environment?(
         %{
           "emisar" => emisar,
           "name" => name,
           "ready" => ready,
           "ref" => ref,
           "repositories" => repositories
         } = environment
       )
       when map_size(environment) == 5 and is_boolean(emisar) and is_boolean(ready) and
              is_list(repositories) and length(repositories) <= 33 do
    text?(name) and String.length(name) <= 80 and bounded_text(ref, 64) == :ok and
      Enum.all?(repositories, &repository?/1)
  end

  defp settings_environment?(_environment), do: false

  defp optional_configuration_identity(nil, nil), do: :ok

  defp optional_configuration_identity(configuration_ref, revision)
       when is_integer(revision) and revision > 0 do
    case Ecto.UUID.cast(configuration_ref) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :invalid_channel_settings}
    end
  end

  defp optional_configuration_identity(_configuration_ref, _revision),
    do: {:error, :invalid_channel_settings}

  defp optional_notice(nil), do: :ok

  # Who changed the settings is a host fact, so it is carried as one: free text
  # is escaped against invented mentions, and this exact pair is the only shape
  # that may render a real one.
  defp optional_notice(%{"actor_ref" => actor, "at" => at} = notice) when map_size(notice) == 2 do
    if slack_user(actor) == :ok and iso8601(at) == :ok,
      do: :ok,
      else: {:error, :invalid_notice}
  end

  defp optional_notice(notice) do
    if text?(notice) and String.length(notice) <= 200, do: :ok, else: {:error, :invalid_notice}
  end

  defp repository?(%{"ref" => ref, "url" => url} = repository) when map_size(repository) == 2,
    do: text?(ref) and byte_size(ref) <= 256 and (is_nil(url) or optional_https_url(url) == :ok)

  defp repository?(_repository), do: false
end
