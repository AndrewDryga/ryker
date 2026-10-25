defmodule Ryker.Slack.ScheduleRunRevisionTest do
  use Ryker.DataCase, async: false
  alias Ryker.Delivery.JSONClient
  alias Ryker.Fixtures.StatusConfirmations
  alias Ryker.Operator
  alias Ryker.Schedules
  alias Ryker.Slack.{AppHomeActions, AppHomeControls, Client, ControlValue, HomeInteraction}
  alias Ryker.Slack.Runtime

  defmodule Directory do
    def user_allowed(_client, _actor, _workspace), do: {:ok, true}
    def shared_conversations(_client, _actor, _workspace), do: {:ok, MapSet.new(["C1"])}
  end

  # A Home view survives a release. An obsolete Run now value must refresh
  # that view without resolving its target or starting work through an old API.
  test "an obsolete Socket Run now value refreshes Home without authorizing work" do
    context = StatusConfirmations.current!(:schedule, :active)
    ["slack", workspace, _channel] = String.split(context.source.conversation_ref, ":")

    envelope = %{
      "envelope_id" => "env-obsolete-home-run",
      "payload" => %{
        "actions" => [
          %{
            "action_id" => "ryker_home_run_schedule",
            "type" => "button",
            "value" => context.entity.ref
          }
        ],
        "container" => %{"type" => "view", "view_id" => "V123"},
        "team" => %{"id" => workspace},
        "type" => "block_actions",
        "user" => %{"id" => "U123"},
        "view" => %{"id" => "V123", "type" => "home"}
      },
      "type" => "interactive"
    }

    assert {:ok, interaction} = HomeInteraction.from_socket(envelope, workspace, Repo.now!())
    parent = self()

    options =
      options(context)
      |> Map.put(:authorize_resource, fn control ->
        send(parent, :authorized_target)
        AppHomeActions.authorize_resource(control, Directory, :client)
      end)

    result = AppHomeControls.handle(interaction, options)
    assert Repo.all(Schedules.ScheduleOccurrence.Query.running(context.entity.id)) == []
    assert StatusConfirmations.fetch!(context) == context.entity
    assert Repo.aggregate(Operator.Action, :count) == 0
    refute_received :authorized_target
    assert result == {:ok, %{outcome: :invalid, resource_ref: context.entity.ref}}
    assert_received :refreshed_home
    refute_received :refreshed_home

    nonoperator = %{interaction | actor_ref: "U124"}
    assert AppHomeControls.handle(nonoperator, options) == {:ok, %{outcome: :denied}}
    refute_received :authorized_target
    refute_received :refreshed_home
  end

  # Home's button, parser, visibility gate and runtime callback must preserve
  # the displayed revision; a fresh callback read would authorize other work.
  test "a retained Home Run now control cannot dispatch its edited replacement" do
    context = StatusConfirmations.current!(:schedule, :active)
    interaction = interaction(context)
    options = options(context)
    edited = StatusConfirmations.edit!(context)
    result = AppHomeControls.handle(interaction, options)

    assert Repo.all(Schedules.ScheduleOccurrence.Query.running(context.entity.id)) == []
    assert StatusConfirmations.fetch!(context) == edited
    refute Repo.exists?(Operator.Action.Query.by_action_ref(interaction.event_ref))
    assert result == {:ok, %{outcome: :invalid, resource_ref: interaction.resource_ref}}
    assert_received :refreshed_home
    refute_received :refreshed_home
  end

  test "a current Home control and its retry share one audited occurrence" do
    context = StatusConfirmations.current!(:schedule, :active)
    interaction = interaction(context)
    options = options(context)
    assert {:ok, %{outcome: :started}} = AppHomeControls.handle(interaction, options)
    assert {:ok, %{outcome: :started}} = AppHomeControls.handle(interaction, options)

    assert [%{trigger: :manual}] =
             Repo.all(Schedules.ScheduleOccurrence.Query.running(context.entity.id))

    action = Repo.fetch!(Operator.Action.Query.by_action_ref(interaction.event_ref))
    assert action.actor_ref == "slack:user:U123"
    assert StatusConfirmations.fetch!(context).revision == context.entity.revision + 1

    assert StatusConfirmations.fetch!(context).next_occurrence_at ==
             context.entity.next_occurrence_at

    assert_received :refreshed_home
    assert_received :refreshed_home
    refute_received :refreshed_home
  end

  defp interaction(context) do
    ["slack", workspace, _channel] = String.split(context.source.conversation_ref, ":")

    %HomeInteraction{
      action: :run_schedule,
      actor_ref: "U123",
      event_ref: "interaction:home-run:#{context.entity.id}",
      occurred_at: Repo.now!(),
      resource_ref: ControlValue.encode("schedule", context.entity.ref, context.entity.revision),
      workspace_ref: workspace
    }
  end

  defp options(context) do
    ["slack", workspace, _channel] = String.split(context.source.conversation_ref, ":")
    parent = self()

    {:ok, http} =
      JSONClient.new(%{
        base_url: "https://slack.com/api",
        finch: Ryker.CoopFinch,
        receive_timeout: 1_000,
        token_provider: fn -> {:ok, "xoxb-test"} end
      })

    {:ok, client} = Client.new(http: http, requester: JSONClient)
    policy = %{digest: String.duplicate("c", 64), name: "scheduled-read"}

    runtime =
      Runtime.options!(%{
        app_http: http,
        bot_client: client,
        default_environment: nil,
        environments: %{},
        identity: %{bot_ref: "B123", bot_user_ref: "U999", workspace_ref: workspace},
        incident_policy: policy,
        operators: ["U123"],
        schedule_policies: %{
          governed_operation_policy: policy,
          read_only_policy: policy,
          repositories: %{},
          worker_ref: "worker:home-run"
        }
      })

    runtime.handler_settings.home_interaction_options
    |> Map.put(:directory, Directory)
    |> Map.put(:authorize_resource, &AppHomeActions.authorize_resource(&1, Directory, :client))
    |> Map.put(:refresh_home, fn _event ->
      send(parent, :refreshed_home)
      {:ok, %{outcome: :published}}
    end)
  end
end
