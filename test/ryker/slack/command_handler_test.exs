defmodule Ryker.Slack.CommandHandlerTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.{Command, CommandHandler}

  defmodule Directory do
    def user_allowed(%{observer: observer, users: users}, actor_ref, workspace_ref) do
      send(observer, {:membership_checked, actor_ref, workspace_ref})
      {:ok, MapSet.member?(users, actor_ref)}
    end
  end

  defmodule ErrorDirectory do
    def user_allowed(_client, _actor_ref, _workspace_ref), do: {:error, :directory_offline}
  end

  test "the emergency kit changes typed settings and explains effective precedence privately" do
    options = options()

    assert {:ok, response} =
             CommandHandler.handle(command("proactive global on", "event:global"), options)

    assert response["response_type"] == "ephemeral"
    assert response["text"] =~ "saved for this channel"
    assert response["text"] =~ "Proactive: on"

    assert_receive {:setting_changed, change}
    assert change.scope == :workspace
    assert change.setting == :proactive
    assert change.value == :on

    assert {:ok, status} = CommandHandler.handle(command("status", "event:status"), options)
    assert status["response_type"] == "ephemeral"
    assert status["text"] =~ "Conversations: Join when useful"
    assert status["text"] =~ "Alerts: Offer an in-place task or incident room"
    refute_received {:setting_changed, _change}
  end

  # /ryker status failed with {:invalid_slack_command, :settings} in every
  # channel that had saved its setup, because the saved configuration answered
  # with source :configuration and the command only knew three sources.
  test "/ryker status shows the saved channel settings privately without changing them" do
    options = options()

    assert {:ok, status} = CommandHandler.handle(command("status", "event:status"), options)
    assert status["response_type"] == "ephemeral"

    [heading, facts, context, controls] = status["blocks"]
    assert heading["text"]["text"] == "*Channel settings*"

    assert Enum.map(facts["fields"], & &1["text"]) == [
             "*Conversations*\nJoin when useful",
             "*Alerts*\nOffer an in-place task or incident room",
             "*Environment*\nProduction, with Emisar",
             "*Repositories*\n<https://github.com/acme/ryker|ryker> — changes\n`docs` — read only",
             "*Incident invitations*\nNo one automatically — you can add people yourself",
             "*Observation mode*\nOff"
           ]

    assert hd(context["elements"])["text"] =~ "saved by <@U123>"

    # A channel outside every environment, in an installation without any,
    # still reads its settings, and a choice made on the channel's web page
    # says where it was made rather than naming a Slack member.
    none = %{
      options
      | settings_view: fn workspace_ref, channel_ref ->
          {:ok, settings} = options.settings_view.(workspace_ref, channel_ref)

          {:ok,
           %{
             settings
             | "customized_by" => "control-plane:local",
               "environment" => nil,
               "environment_count" => 0
           }}
        end
    }

    assert {:ok, outside} = CommandHandler.handle(command("status", "event:status-none"), none)
    [_heading, facts, context, _controls] = outside["blocks"]

    assert Enum.slice(Enum.map(facts["fields"], & &1["text"]), 2, 2) == [
             "*Environment*\nNo environment",
             "*Repositories*\nNone"
           ]

    assert hd(context["elements"])["text"] =~ "changed in Ryker's settings"

    assert [%{"action_id" => "ryker_welcome_configure", "value" => value}] =
             controls["elements"]

    assert value =~ ~r/\A[0-9a-f-]{36}\|4\z/
    refute_received {:setting_changed, _change}

    overridden =
      %{
        options
        | effective_settings: fn _workspace_ref, _conversation_ref ->
            %{
              proactive: %{source: :installation, value: true},
              shadow: %{source: :incident_room, value: false}
            }
          end
      }

    assert {:ok, override} =
             CommandHandler.handle(command("proactive global on", "event:override"), overridden)

    assert override["text"] =~ "Proactive: on (installation default)"
  end

  test "assignment creation is conversational while scoped grants can be listed or withdrawn" do
    options = options()

    assert {:ok, listed} = CommandHandler.handle(command("assignments", "event:list"), options)
    assert listed["text"] =~ "assignment:terraform"
    assert listed["text"] =~ "review_terraform_plan"

    assert {:ok, paused} =
             CommandHandler.handle(
               command("assignments pause behavior:assignment:terraform", "event:pause"),
               options
             )

    assert paused["text"] =~ "Paused"

    assert_receive {:assignment_changed, "behavior:assignment:terraform", :disabled, scope}
    assert scope.conversation_ref == "slack:T123:C456"

    assert {:ok, create} =
             CommandHandler.handle(command("assignments create", "event:create"), options)

    assert create["text"] =~ "Ask for the standing assignment in ordinary language"
  end

  test "non-operators and non-members are denied before any write" do
    denied_operator = %{options() | operators: MapSet.new()}

    assert {:ok, denied} =
             CommandHandler.handle(command("proactive on", "event:denied"), denied_operator)

    assert denied["text"] =~ "configured Ryker operator"
    refute_received {:setting_changed, _change}

    denied_member = put_in(options(), [:client, :users], MapSet.new())

    assert {:ok, denied} =
             CommandHandler.handle(command("shadow on", "event:guest"), denied_member)

    assert denied["text"] =~ "active full workspace member"
    refute_received {:setting_changed, _change}
  end

  test "unknown and malformed verbs answer with the emergency kit" do
    # Retired subcommands used to get a per-verb pointer table; that was a
    # compatibility shim for commands nobody can discover any more, so every
    # verb outside the kit is simply unknown and gets the same help text.
    assert {:ok, unknown} =
             CommandHandler.handle(command("incidents", "event:unknown"), options())

    assert unknown["text"] =~ "Unknown `/ryker` subcommand `incidents`."
    assert unknown["text"] =~ "Ryker emergency kit"

    assert {:ok, invalid} =
             CommandHandler.handle(command("proactive sometimes", "event:invalid"), options())

    assert invalid["text"] =~ "on|off|inherit"
  end

  test "the whole emergency command surface remains deterministic and fail closed" do
    options = options()

    for text <- ["", "help"] do
      assert {:ok, response} = CommandHandler.handle(command(text, "event:help:#{text}"), options)
      assert response["text"] =~ "Ryker emergency kit"
    end

    for text <- ["settings", "config"] do
      assert {:ok, response} =
               CommandHandler.handle(command(text, "event:status:#{text}"), options)

      assert response["text"] =~ "Channel settings"
    end

    for {text, setting, scope, value} <- [
          {"watch off", :proactive, :channel, :off},
          {"proactive inherit", :proactive, :channel, :inherit},
          {"shadow global on", :shadow, :workspace, :on}
        ] do
      assert {:ok, response} =
               CommandHandler.handle(command(text, "event:setting:#{text}"), options)

      assert response["response_type"] == "ephemeral"
      assert_receive {:setting_changed, %{setting: ^setting, scope: ^scope, value: ^value}}
    end

    empty_assignments = %{options | list_assignments: fn _, _ -> [] end}

    for text <- ["assignment", "assignments list"] do
      assert {:ok, response} =
               CommandHandler.handle(
                 command(text, "event:assignments:#{text}"),
                 empty_assignments
               )

      assert response["text"] =~ "No standing assignments"
    end

    for {verb, status, label} <- [
          {"resume", :active, "Resumed"},
          {"delete", :deleted, "Deleted"}
        ] do
      assert {:ok, response} =
               CommandHandler.handle(
                 command("assignment #{verb} behavior:assignment:terraform", "event:#{verb}"),
                 options
               )

      assert response["text"] =~ label
      assert_receive {:assignment_changed, "behavior:assignment:terraform", ^status, _scope}
    end

    assert {:ok, usage} =
             CommandHandler.handle(command("assignments rename one", "event:usage"), options)

    assert usage["text"] =~ "pause|resume|delete"

    assert {:ok, unknown} =
             CommandHandler.handle(command("definitely-unknown", "event:unknown"), options)

    assert unknown["text"] =~ "Unknown"
  end

  test "operator dependencies cannot smuggle malformed settings or assignment failures" do
    command = command("status", "event:dependency")

    assert CommandHandler.handle(command, %{options() | directory: ErrorDirectory}) ==
             {:error, :directory_offline}

    invalid_settings = %{options() | settings_view: fn _, _ -> %{proactive: true} end}

    assert CommandHandler.handle(command, invalid_settings) ==
             {:error, {:invalid_slack_command, :settings}}

    settings_error = %{options() | settings_view: fn _, _ -> {:error, :settings_offline} end}
    assert CommandHandler.handle(command, settings_error) == {:error, :settings_offline}

    malformed_view = %{
      options()
      | settings_view: fn _, _ -> {:ok, %{"alert_policy" => "loud"}} end
    }

    assert CommandHandler.handle(command, malformed_view) ==
             {:error, {:invalid_slack_render, :channel_settings}}

    invalid_effective = %{options() | effective_settings: fn _, _ -> %{proactive: true} end}

    assert CommandHandler.handle(command("shadow off", "event:effective"), invalid_effective) ==
             {:error, {:invalid_slack_command, :settings}}

    change_error = %{options() | change_setting: fn _change -> {:error, :store_offline} end}

    assert CommandHandler.handle(command("shadow off", "event:store"), change_error) ==
             {:error, :store_offline}

    for reason <- [:behavior_not_found, :behavior_terminal, :assignment_scope_mismatch] do
      unavailable = %{options() | manage_assignment: fn _, _, _ -> {:error, reason} end}

      assert {:ok, response} =
               CommandHandler.handle(
                 command("assignments pause behavior:missing", "event:#{reason}"),
                 unavailable
               )

      assert response["text"] =~ "not active in this channel"
    end

    failing = %{options() | manage_assignment: fn _, _, _ -> {:error, :store_offline} end}

    assert CommandHandler.handle(
             command("assignments pause behavior:any", "event:assignment-store"),
             failing
           ) == {:error, :store_offline}

    assert CommandHandler.handle(:invalid, %{}) ==
             {:error, {:invalid_slack_command, :input}}
  end

  defp command(text, event_ref) do
    %Command{
      actor_ref: "U123",
      channel_ref: "C456",
      event_ref: event_ref,
      occurred_at: ~U[2026-08-28 12:00:00.000000Z],
      text: text,
      workspace_ref: "T123"
    }
  end

  defp options do
    observer = self()

    %{
      bot_user_ref: "UBOT",
      change_setting: fn change ->
        send(observer, {:setting_changed, change})
        {:ok, %{status: :updated}}
      end,
      client: %{observer: observer, users: MapSet.new(["U123"])},
      directory: Directory,
      effective_settings: fn _workspace_ref, _conversation_ref ->
        %{
          proactive: %{source: :channel, value: true},
          shadow: %{source: :installation, value: false}
        }
      end,
      settings_view: fn _workspace_ref, _channel_ref ->
        {:ok,
         %{
           "alert_policy" => "offer",
           "configuration_ref" => "6a2f8a5e-2f6a-4a6d-9d2f-2c3f4e5a6b7c",
           "customized_by" => "U123",
           "environment" => %{
             "emisar" => true,
             "name" => "Production",
             "ready" => true,
             "ref" => "production",
             "repositories" => [
               %{"ref" => "ryker", "url" => "https://github.com/acme/ryker"},
               %{"ref" => "docs", "url" => nil}
             ]
           },
           "environment_count" => 2,
           "invitations" => %{"user_group_refs" => [], "user_refs" => []},
           "observation" => %{"on" => false, "source" => "channel"},
           "participation" => %{"source" => "channel", "value" => "proactive"},
           "revision" => 4
         }}
      end,
      list_assignments: fn _workspace_ref, _conversation_ref ->
        [
          %{
            payload: %{"action" => "review_terraform_plan"},
            ref: "behavior:assignment:terraform",
            status: :active
          }
        ]
      end,
      manage_assignment: fn ref, status, scope ->
        send(observer, {:assignment_changed, ref, status, scope})
        {:ok, %{ref: ref, status: status}}
      end,
      operators: MapSet.new(["U123"])
    }
  end
end
