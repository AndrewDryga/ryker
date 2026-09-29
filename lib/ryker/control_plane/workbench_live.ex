defmodule Ryker.ControlPlane.WorkbenchLive do
  @moduledoc """
  Live operator workspace. Browser state never owns execution custody.

  One LiveView serves every page. An open page redraws when something it
  shows changes, and only then: each page declares the topics it listens to
  (`page_subscriptions/3`, which dispatches to the page modules and to
  `Pages.subscriptions/2`), and the shell adds what every page can show (Slack
  names, history a retention pass removed) and, until setup is done, what the
  sidebar's setup count reads. The page subscribes when the socket connects
  and before every read, drops the topics of the page it left, and turns any
  burst of announcements into one reload a moment later
  (`schedule_reload/2`, `reload_drained/1`). Nothing re-reads a page on a
  timer; a read that failed is retried with backoff until it succeeds.
  """
  use Phoenix.LiveView, layout: false
  require Logger

  alias Phoenix.HTML.Safe

  alias Ryker.ControlPlane.{
    Activity,
    ActivityPage,
    BehaviorPage,
    ChannelDetail,
    ChannelPage,
    Components,
    ConfigurationGuide,
    ConversationLab,
    ConversationProjection,
    Endpoint,
    Environments,
    EpisodePage,
    EpisodeProjection,
    IntegrationErrors,
    Integrations,
    Kit,
    LabControls,
    LabPage,
    Navigation,
    PageHelp,
    Pages,
    PathRef,
    RepositoriesPage,
    RequestFilters,
    Router,
    RunningSystem,
    SettingsPage,
    SettingsView,
    UsageProjection
  }

  alias Ryker.{IntegrationSetup, RepositoryKnowledge, Settings}
  alias Ryker.Retention.Data, as: RetentionData
  alias Ryker.Slack.{ChannelConfigurations, Names}

  # Who a choice made on these pages is recorded as, like every other
  # control-plane write.
  @actor_ref "control-plane:local"
  @confirmed_settings_actions ~w(disconnect-slack disconnect-github delete-emisar delete-environment delete-webhook-credential turn-off-learning remove-repository leave-channel)
  @settings_pages %{
    ["setup"] => :setup,
    ["environments"] => :environments,
    ["integrations"] => :integrations,
    ["integrations", "slack"] => :slack,
    ["integrations", "github"] => :github,
    ["integrations", "emisar"] => :emisar,
    ["integrations", "webhooks"] => :webhooks,
    ["settings"] => :settings,
    ["settings", "models"] => :model,
    ["settings", "retention"] => :retention,
    ["settings", "prices"] => :pricing,
    ["settings", "report"] => :report,
    ["settings", "advanced"] => :system
  }

  # A burst of announcements (a turn finishing writes a dozen rows) redraws a
  # page once, this long after the first of them.
  @reload_debounce_ms 100

  # What the topics pages listen to announce; each context documents its own
  # (`Ryker.Episodes.subscribe_episode/1`, ...). The page hears only the topics
  # it declared, so any of these redraws it.
  @page_events ~w(
    behavior_updated conversation_updated continuity_updated coop_worker_updated
    credentials_changed emisar_approval_updated episode_updated feedback_recorded follow_up_updated
    github_delivery_updated history_pruned improvement_updated incident_room_updated input_updated
    instructions_saved
    knowledge_updated learning_updated local_routing_updated memory_updated operator_action_recorded
    platform_action_updated publication_updated record_updated repository_knowledge_updated
    routing_response_updated schedule_updated settings_applied settings_saved slack_channel_updated
    slack_connection_changed slack_interaction_updated slack_names_updated
    task_card_updated thread_status_updated usage_recorded weekly_report_updated
    work_session_updated
  )a

  @doc false
  def page_events, do: @page_events

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       path: "/",
       params: %{},
       body: "",
       page_title: "Activity",
       page_description: nil,
       page_action: nil,
       page_back: nil,
       page_state: nil,
       page_title_href: nil,
       connected: connected?(socket),
       unavailable: false,
       reload_scheduled?: false,
       refresh_failures: 0,
       subscriptions: [],
       observed_at: nil,
       native: nil,
       page_status: 200,
       instructions: nil,
       instruction_scope: nil,
       body_lead: "",
       save_instructions: nil,
       settings: nil,
       settings_commands: nil,
       settings_error: nil,
       settings_section: :setup,
       setup_notice: nil,
       setup_failure: nil,
       setup_reveal: nil,
       settings_confirm: nil,
       setup_progress: nil,
       github_repositories: [],
       github_repository_discovery: :idle,
       repository_notice: nil,
       repository_question: nil,
       knowledge_question: nil,
       channel_notice: nil,
       welcome_pending: nil,
       slack_members: [],
       settings_form: nil,
       weekly_preview: nil,
       weekly_sent: nil,
       carried_notice: nil,
       action_question: nil,
       overview: nil,
       activity: nil,
       filter_menu: nil,
       filter_values: [],
       schedules: [],
       row_ids: [],
       row_days: %{},
       new_items: 0,
       episode: nil,
       disclosed: MapSet.new(),
       requests: nil,
       lab: nil,
       lab_token: nil,
       lab_announcement: "",
       lab_items: [],
       lab_filter: "",
       lab_window: nil,
       lab_draft_id: nil,
       lab_environment: nil,
       lab_environment_saved: nil,
       lab_environments: [],
       readiness: nil
     )
     |> stream_configure(:activity, dom_id: &dom_id/1)
     |> stream(:activity, [])
     |> stream_configure(:lab_messages, dom_id: &lab_dom_id/1)
     |> stream(:lab_messages, [])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    location = URI.parse(uri)

    {:noreply,
     socket
     |> assign(
       path: location.path,
       params: params,
       filter_menu: nil,
       disclosed: navigation_disclosures(socket, location.path),
       native: :loading,
       page_status: 200,
       body: "",
       page_title: "Workspace",
       page_description: nil,
       page_back: nil,
       page_state: nil,
       page_title_href: nil,
       observed_at: nil,
       # An outcome or an open question belongs to the page it happened on. A
       # form that saved returns to its list and carries what the save did
       # there (`return_with/3`), so the list says it.
       setup_notice:
         socket.assigns.carried_notice ||
           if(location.path == socket.assigns.path, do: socket.assigns.setup_notice),
       carried_notice: nil,
       repository_notice:
         if(location.path == socket.assigns.path,
           do: socket.assigns.repository_notice,
           else: carried_repository_notice(socket.assigns.repository_notice, location.path)
         ),
       setup_failure: nil,
       settings_confirm: nil,
       weekly_sent: nil,
       action_question: nil,
       channel_notice: nil,
       welcome_pending: nil,
       lab_environment_saved: nil
     )
     |> assign_conversation_draft(location.path)
     |> reset_repository_discovery(location.path, socket.assigns.path)
     |> refresh(true)}
  end

  # What an import added is said on the list it returned to; every other
  # outcome on Repositories stays with the page it happened on.
  defp carried_repository_notice({:list, _tone, _message} = notice, "/repositories"),
    do: notice

  defp carried_repository_notice(_notice, _path), do: nil

  # The list and each repository's page say what their buttons did; the add
  # page says it in its own form.
  defp repository_page?("/repositories"), do: true
  defp repository_page?("/repositories/new"), do: false
  defp repository_page?("/repositories/" <> _ref), do: true
  defp repository_page?(_path), do: false

  # Each visit to Add repositories lists what the GitHub App reaches afresh,
  # giving up a listing the last visit left under way.
  defp reset_repository_discovery(socket, "/repositories/new", "/repositories/new"), do: socket

  defp reset_repository_discovery(socket, "/repositories/new", _previous) do
    socket
    |> cancel_async(:github_repositories)
    |> assign(github_repositories: [], github_repository_discovery: :idle)
  end

  defp reset_repository_discovery(socket, _path, _previous), do: socket

  # A conversation view is opened once per navigation: the index gets a fresh
  # identity nothing is written behind. Reloads come through refresh/2, not
  # here, so an announcement cannot hand the draft a new identity.
  defp assign_conversation_draft(socket, "/conversations"),
    do: assign(socket, lab_draft_id: Ecto.UUID.generate())

  defp assign_conversation_draft(socket, _path), do: assign(socket, lab_draft_id: nil)

  # Reading state belongs to one record. Navigating to a different Timeline must
  # not carry another record's opened bodies, which would load evidence the
  # reader never asked for on this page.
  defp navigation_disclosures(socket, path) do
    if socket.assigns.path == path, do: socket.assigns.disclosed, else: MapSet.new()
  end

  # -- Live updates -------------------------------------------------------------

  # Subscribes to what the page at the socket's path listens to and drops what
  # the page it replaced listened to. It runs before every read of a page, so
  # an announcement made while the page reads is heard and reloads it again.
  defp listen(socket) do
    if connected?(socket) do
      wanted = Enum.uniq(page_subscriptions(socket) ++ shell_subscriptions(socket))
      held = socket.assigns.subscriptions
      Enum.each(held -- wanted, &unsubscribe/1)
      Enum.each(wanted -- held, &subscribe/1)
      assign(socket, :subscriptions, wanted)
    else
      socket
    end
  end

  defp page_subscriptions(%{assigns: %{path: path, params: params} = assigns}),
    do: page_subscriptions(path, params, assigns.lab_draft_id)

  # Each page declares its topics beside what it shows; the native pages are
  # dispatched here as `load_page/3` loads them, every other page by `Pages`.
  # `draft_id` is the identity an empty Chat draft will start.
  @doc false
  def page_subscriptions(path, params, draft_id) do
    segments = String.split(path, "/", trim: true)

    case settings_route(segments, params) do
      {:setup, nil} -> SettingsView.setup_subscriptions()
      {_section, _form} -> SettingsView.subscriptions()
      nil -> page_subscriptions_at(segments, params, draft_id)
    end
  end

  defp page_subscriptions_at(segments, _params, _draft_id) when segments in [[], ["activity"]],
    do: ActivityPage.subscriptions()

  defp page_subscriptions_at(["timeline", _ref], params, _draft_id),
    do: EpisodeProjection.subscriptions(params["ref"])

  defp page_subscriptions_at(["instructions"], _params, _draft_id),
    do: BehaviorPage.subscriptions(:instructions)

  defp page_subscriptions_at(["channels", _workspace, _channel], params, _draft_id),
    do: ChannelPage.subscriptions(params["workspace"], params["channel"])

  defp page_subscriptions_at(["conversations"], _params, draft_id),
    do: LabPage.subscriptions(draft_id)

  defp page_subscriptions_at(["conversations", _id], params, _draft_id),
    do: LabPage.subscriptions(params["id"])

  defp page_subscriptions_at(segments, params, _draft_id),
    do: Pages.subscriptions(segments, params)

  # Every page can show Slack names (`Kit`, `Components`) and history a
  # retention pass removes in bulk, and until setup is done the sidebar counts
  # its steps on every page.
  @shell_subscriptions [{Names, :subscribe_names, []}, {RetentionData, :subscribe_pruning, []}]

  defp shell_subscriptions(%{assigns: %{setup_progress: nil}}), do: @shell_subscriptions

  defp shell_subscriptions(_socket),
    do: @shell_subscriptions ++ SettingsView.setup_subscriptions()

  defp subscribe({module, function, arguments}), do: apply(module, function, arguments)

  defp unsubscribe({module, "subscribe" <> _rest = function, arguments}),
    do: apply(module, String.to_existing_atom("un" <> function), arguments)

  defp unsubscribe({module, function, arguments}),
    do: unsubscribe({module, Atom.to_string(function), arguments})

  defp schedule_reload(socket, delay \\ @reload_debounce_ms) do
    if socket.assigns.reload_scheduled? do
      socket
    else
      Process.send_after(self(), :reload_page, delay)
      assign(socket, :reload_scheduled?, true)
    end
  end

  defp reload_drained(socket), do: assign(socket, :reload_scheduled?, false)

  @impl true
  def handle_info(event, socket)
      when is_tuple(event) and tuple_size(event) > 1 and elem(event, 0) in @page_events,
      do: {:noreply, schedule_reload(socket)}

  # A page that could not be read is read afresh, the way Try again reads it.
  # Merged into what the failed read left, Activity came back empty behind
  # "N new or reordered items" after a database blip.
  def handle_info(:reload_page, socket),
    do: {:noreply, socket |> reload_drained() |> refresh(socket.assigns.unavailable)}

  def handle_info({:settings_editor_saved, view}, socket) do
    {:noreply, assign(socket, settings: {:ok, view}, settings_error: nil)}
  end

  # The Learning page says whether learning is on in its body, so the switch
  # redraws the page at once; waiting for the next refresh left the line one
  # step behind the button.
  def handle_info({:learning_switched, view}, socket) do
    {:noreply,
     socket
     |> assign(settings: {:ok, view}, settings_error: nil, settings_confirm: nil)
     |> refresh()}
  end

  # The welcome redraw a channel's setting change asked for, back from Slack.
  # Only the page that asked hears it, and only a redraw that did not work
  # changes what it says: the change itself was saved already, so the saved
  # mark stays and a note says the welcome still shows the old setting.
  def handle_info({:channel_welcome_redrawn, workspace, channel, result}, socket) do
    case {socket.assigns.welcome_pending, result} do
      {{^workspace, ^channel, _name, _key}, {:ok, _delivered}} ->
        {:noreply, assign(socket, :welcome_pending, nil)}

      # The channel page renders its notice when it loads, so it loads again.
      {{^workspace, ^channel, name, key}, {:error, reason}} ->
        {:noreply,
         socket
         |> assign(
           channel_notice: {:saved, name, key, welcome_not_redrawn(reason)},
           welcome_pending: nil
         )
         |> refresh()}

      _another_page ->
        {:noreply, socket}
    end
  end

  # A saved environment returns to the list, which says so.
  def handle_info({:environment_saved, view, message}, socket) do
    {:noreply,
     socket
     |> assign(settings: {:ok, view}, setup_failure: nil)
     |> return_with("/environments", message)}
  end

  # A row of a settings list saved on its own page returns to that list.
  def handle_info({:settings_item_saved, view, list, message}, socket) do
    {:noreply,
     socket
     |> assign(settings: {:ok, view}, setup_failure: nil)
     |> return_with(list, message)}
  end

  # Anything else, such as a reply to a request this page no longer waits
  # for, changes nothing it shows.
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:github_repositories, {:ok, {:ok, repositories}}, socket),
    do:
      {:noreply,
       assign(socket, github_repositories: repositories, github_repository_discovery: :complete)}

  def handle_async(:github_repositories, {:ok, {:error, reason}}, socket),
    do:
      {:noreply,
       assign(socket, github_repository_discovery: {:error, IntegrationErrors.message(reason)})}

  # A listing given up for the next visit's (`reset_repository_discovery/3`)
  # did not fail; it says nothing.
  def handle_async(:github_repositories, {:exit, {:shutdown, :cancel}}, socket),
    do: {:noreply, socket}

  def handle_async(:github_repositories, {:exit, _reason}, socket),
    do:
      {:noreply,
       assign(socket,
         github_repository_discovery:
           {:error, "Ryker could not list the repositories. Refresh to try again."}
       )}

  @impl true
  def handle_event(event, _params, socket) when event in ["refresh", "show-new"],
    do: {:noreply, refresh(socket, true)}

  def handle_event(
        "edit-lab-message",
        %{
          "_token" => token,
          "conversation_id" => conversation_id,
          "item_id" => item_id,
          "message" => message
        },
        socket
      ) do
    options = Endpoint.config(:control_plane)

    result =
      with {:ok, conversation_id} <- PathRef.uuid(conversation_id),
           {:ok, item_id} <- PathRef.uuid(item_id),
           true <-
             LabControls.valid_message_token?(
               options.csrf_secret,
               conversation_id,
               item_id,
               :edit,
               token
             ),
           {:ok, _receipt} <- options.actions.edit_lab_message.(conversation_id, item_id, message) do
        {:ok, item_id}
      else
        false -> {:error, :unauthorized}
        {:error, reason} -> {:error, reason}
      end

    lab_mutation_result(socket, :edit, item_id, result)
  end

  def handle_event(
        "delete-lab-message",
        %{
          "_token" => token,
          "conversation_id" => conversation_id,
          "item_id" => item_id
        },
        socket
      ) do
    options = Endpoint.config(:control_plane)

    result =
      with {:ok, conversation_id} <- PathRef.uuid(conversation_id),
           {:ok, item_id} <- PathRef.uuid(item_id),
           true <-
             LabControls.valid_message_token?(
               options.csrf_secret,
               conversation_id,
               item_id,
               :delete,
               token
             ),
           {:ok, _receipt} <- options.actions.delete_lab_message.(conversation_id, item_id) do
        {:ok, item_id}
      else
        false -> {:error, :unauthorized}
        {:error, reason} -> {:error, reason}
      end

    lab_mutation_result(socket, :delete, item_id, result)
  end

  def handle_event(
        "react-to-lab-message",
        %{
          "_token" => token,
          "action" => action,
          "conversation_id" => conversation_id,
          "emoji" => emoji,
          "message_ref" => message_ref
        },
        socket
      ) do
    options = Endpoint.config(:control_plane)

    result =
      with {:ok, conversation_id} <- PathRef.uuid(conversation_id),
           {:ok, message_ref} <- PathRef.decode(message_ref),
           {:ok, action} <- lab_reaction_action(action),
           true <-
             LabControls.valid_reaction_token?(
               options.csrf_secret,
               conversation_id,
               message_ref,
               token
             ),
           {:ok, _transition} <-
             options.actions.react_to_lab_message.(conversation_id, message_ref, action, emoji) do
        {:ok, message_ref}
      else
        false -> {:error, :unauthorized}
        {:error, reason} -> {:error, reason}
      end

    lab_mutation_result(socket, :reaction, message_ref, result)
  end

  def handle_event("initialize-settings", _params, socket) do
    case initialize_settings(socket) do
      {:ok, snapshot} ->
        {:noreply,
         assign(socket, settings: {:ok, SettingsView.view(snapshot)}, settings_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :settings_error, initialize_error(reason))}
    end
  end

  # The report as it would read now, posted to its channel as a preview; the
  # card says what became of it.
  def handle_event("send-weekly-report-preview", _params, socket) do
    sent =
      case socket.assigns.settings_commands.send_weekly_report_preview.() do
        {:ok, _report} ->
          {:ok,
           "Sent. It shows in the channel in a moment; if Slack refuses it, it is on Failures."}

        {:error, :no_channel} ->
          {:error, "Choose the report's channel and connect Slack before sending a preview."}

        {:error, _reason} ->
          {:error, "Ryker could not send the preview. Nothing was posted."}
      end

    {:noreply, assign(socket, :weekly_sent, sent)}
  end

  def handle_event("connect-slack", %{"connection" => params}, socket) do
    case IntegrationSetup.connect_slack(params) do
      # New tokens for the workspace Slack already works in keep it on, for
      # the same people, so there is nobody to choose again.
      {:ok, %{enabled: true}} ->
        {:noreply,
         socket
         |> refresh_settings()
         |> assign(
           setup_notice: "The new tokens are verified. Slack stays on for the same people.",
           setup_failure: nil,
           setup_reveal: nil,
           slack_members: []
         )}

      {:ok, _off} ->
        members =
          case IntegrationSetup.slack_members() do
            {:ok, found} -> found
            _error -> []
          end

        {:noreply,
         socket
         |> refresh_settings()
         |> assign(
           setup_notice: "Slack is verified.",
           setup_failure: nil,
           setup_reveal: nil,
           slack_members: members
         )}

      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  def handle_event("load-slack-members", _params, socket) do
    case IntegrationSetup.slack_members() do
      {:ok, members} ->
        {:noreply, assign(socket, slack_members: members, setup_notice: nil, setup_failure: nil)}

      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  def handle_event("cancel-slack-members", _params, socket),
    do: {:noreply, assign(socket, :slack_members, [])}

  # Choosing who can manage Ryker finishes connecting Slack and changes nothing
  # else. Until 2026-09-24 this save also wrote "only when mentioned" as the
  # default for every channel, undoing whatever the operator had chosen there.
  def handle_event("save-slack-choices", params, socket) do
    allowed_members = MapSet.new(socket.assigns.slack_members, & &1.id)

    operators =
      params
      |> Map.get("operators", [])
      |> List.wrap()
      |> Enum.filter(&MapSet.member?(allowed_members, &1))

    view = elem(socket.assigns.settings, 1)

    case Settings.save_slack(
           %{enabled: true, operators: operators},
           view.revision,
           Settings.actor()
         ) do
      {:ok, _snapshot} ->
        {:noreply,
         socket
         |> refresh_settings()
         |> assign(
           setup_notice: "Saved who can manage Ryker.",
           setup_failure: nil,
           slack_members: []
         )}

      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  def handle_event("connect-github", %{"connection" => params}, socket) do
    case IntegrationSetup.connect_github(params) do
      {:ok, result} ->
        {:noreply,
         socket
         |> refresh_settings()
         |> assign(
           setup_notice: "GitHub App #{result.app_slug} is verified.",
           setup_failure: nil,
           setup_reveal: %{label: "GitHub webhook secret", value: result.webhook_secret}
         )}

      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  # Add repositories lists what the GitHub App reaches when it opens; this
  # lists it again, keeping what was ticked (repository-picker.mjs).
  def handle_event("refresh-github-repositories", _params, socket) do
    if socket.assigns.github_repository_discovery == :loading,
      do: {:noreply, socket},
      else:
        {:noreply,
         socket
         |> assign(repository_notice: nil)
         |> discover_github_repositories(Endpoint.config(:control_plane))}
  end

  def handle_event("import-github-repositories", params, socket) do
    selected = params |> Map.get("repository_ids", []) |> List.wrap() |> MapSet.new()

    repositories =
      if Map.get(params, "import_mode") == "all" do
        Enum.reject(socket.assigns.github_repositories, & &1.already_present)
      else
        Enum.filter(socket.assigns.github_repositories, fn repository ->
          MapSet.member?(selected, to_string(repository.repository_id))
        end)
      end

    case IntegrationSetup.import_github_repositories(repositories,
           auto_add_repositories: Map.get(params, "auto_add_repositories") == "true"
         ) do
      # The picker marks what is now added, so a second "Add selected" cannot
      # repeat the first. An import that added everything chosen returns to
      # the list, which has the new rows and says so; anything else stays on
      # the form, which says what is left to do.
      {:ok, result} ->
        handled = MapSet.new(result.added ++ result.already_present)
        tone = import_tone(result)
        message = import_message(result, default_environment())

        socket =
          assign(socket,
            github_repositories:
              Enum.map(socket.assigns.github_repositories, fn repository ->
                if MapSet.member?(handled, repository.full_name),
                  do: %{repository | already_present: true},
                  else: repository
              end)
          )

        {:noreply,
         if(tone == :success,
           do:
             socket
             |> assign(repository_notice: {:list, tone, message})
             |> push_patch(to: "/repositories"),
           else: socket |> assign(repository_notice: {:import, tone, message}) |> refresh(true)
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket, repository_notice: {:import, :error, IntegrationErrors.message(reason)})}
    end
  end

  # A connected account returns to the list of accounts, which says where it
  # is used; a refused one keeps its form open and says why.
  def handle_event("connect-emisar", %{"connection" => params}, socket) do
    case IntegrationSetup.connect_emisar(params) do
      {:ok, _connection} = result ->
        {:noreply,
         socket
         |> refresh_settings()
         |> assign(setup_failure: nil, setup_reveal: nil)
         |> return_with("/integrations/emisar", emisar_connected(result))}

      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  def handle_event("rotate-emisar", %{"connection" => params}, socket) do
    result =
      IntegrationSetup.rotate_emisar(Map.get(params, "ref", ""), Map.get(params, "token", ""))

    {:noreply, finish_setup(socket, result, "The Emisar key was replaced.")}
  end

  def handle_event("disable-emisar", %{"ref" => ref}, socket) when is_binary(ref) do
    {:noreply,
     finish_setup(
       socket,
       IntegrationSetup.disable_emisar(ref),
       "New work will not use this account."
     )}
  end

  def handle_event("enable-emisar", %{"ref" => ref}, socket) when is_binary(ref) do
    {:noreply,
     finish_setup(socket, IntegrationSetup.enable_emisar(ref), "This account can serve new work.")}
  end

  def handle_event("disable-emisar-monitoring", %{"ref" => ref}, socket)
      when is_binary(ref) do
    {:noreply,
     finish_setup(
       socket,
       IntegrationSetup.disable_emisar_monitoring(ref),
       "Approval monitoring is off for this account."
     )}
  end

  def handle_event("enable-emisar-monitoring", %{"ref" => ref}, socket)
      when is_binary(ref) do
    {:noreply,
     finish_setup(
       socket,
       IntegrationSetup.enable_emisar_monitoring(ref),
       "Approval monitoring is on for this account."
     )}
  end

  def handle_event("rename-emisar", %{"connection" => params}, socket) do
    result =
      IntegrationSetup.rename_emisar(
        Map.get(params, "ref", ""),
        Map.get(params, "display_name", "")
      )

    {:noreply, finish_setup(socket, result, "Emisar account name was updated.")}
  end

  # A removed account's page is gone, so its removal returns to the list.
  def handle_event("delete-emisar", %{"ref" => ref}, socket) when is_binary(ref) do
    confirmed(socket, {"delete-emisar", ref}, fn socket ->
      case IntegrationSetup.delete_emisar(ref) do
        {:ok, _snapshot} ->
          socket
          |> refresh_settings()
          |> assign(setup_failure: nil)
          |> return_with("/integrations/emisar", "The Emisar account was removed.")

        {:error, reason} ->
          failed(socket, reason)
      end
    end)
  end

  # A channel's settings are its own, changed in place on its page as they
  # change and saved the way the channel's setup in Slack saves them.
  def handle_event("set-channel-participation", params, socket),
    do: change_channel_setting(socket, params, "participation")

  def handle_event("set-channel-alerts", params, socket),
    do: change_channel_setting(socket, params, "alert_policy")

  # Removing Ryker from a channel asks first; its question's button leaves.
  # The ref is the channel's "workspace/channel".
  def handle_event("leave-channel", %{"ref" => ref}, socket) when is_binary(ref),
    do: confirmed(socket, {"leave-channel", ref}, &leave_channel(&1, ref))

  def handle_event("select-channel-environment", params, socket),
    do: change_channel_setting(socket, params, "environment")

  def handle_event("delete-environment", %{"ref" => ref}, socket) when is_binary(ref),
    do: confirmed(socket, {"delete-environment", ref}, &delete_environment(&1, ref))

  def handle_event("create-webhook-credential", %{"credential" => params}, socket) do
    case IntegrationSetup.create_webhook_credential(
           Map.get(params, "name", ""),
           Map.get(params, "secret")
         ) do
      # The list shows the secret once, beside the credential it signs for.
      {:ok, result} ->
        {:noreply,
         socket
         |> refresh_settings()
         |> assign(
           setup_failure: nil,
           setup_reveal: %{label: "Signing secret", value: result.secret}
         )
         |> return_with(
           "/integrations/webhooks",
           "Signing credential #{result.name} is ready."
         )}

      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  # A confirmed action's button asks in a modal over the page it is on; the
  # modal's own button posts the action, as its confirmation page's would.
  # One that is gone since the page was drawn draws the page again instead.
  def handle_event("ask-action", %{"path" => path} = params, socket) when is_binary(path) do
    case Router.question(path, Endpoint.config(:control_plane)) do
      {:ok, question} ->
        {:noreply,
         assign(
           socket,
           :action_question,
           Map.put(question, :label, button_label(params["label"]))
         )}

      {:error, :not_found} ->
        {:noreply, socket |> assign(:action_question, nil) |> refresh(true)}
    end
  end

  def handle_event("cancel-action", _params, socket),
    do: {:noreply, assign(socket, :action_question, nil)}

  # Removing a repository asks over the list, in words that say what it does.
  def handle_event(
        "confirm-settings-action",
        %{"action" => "remove-repository", "ref" => ref},
        socket
      )
      when is_binary(ref),
      do: {:noreply, ask_remove_repository(socket, ref)}

  # Refreshing a repository's RYKER.md asks over the list too: it spends a
  # model turn.
  def handle_event(
        "confirm-settings-action",
        %{"action" => "refresh-knowledge", "ref" => ref},
        socket
      )
      when is_binary(ref),
      do: {:noreply, ask_refresh_knowledge(socket, ref)}

  # Anything on the settings pages that disconnects or deletes asks first. The
  # button that starts it only opens the question; the action runs when the
  # question's own button sends it, so a double click never gets past it.
  def handle_event("confirm-settings-action", %{"action" => action, "ref" => ref}, socket)
      when action in @confirmed_settings_actions and is_binary(ref),
      do:
        {:noreply,
         assign(socket, settings_confirm: {action, ref}, setup_notice: nil, setup_failure: nil)}

  def handle_event("cancel-settings-action", _params, socket),
    do: {:noreply, assign(socket, settings_confirm: nil, knowledge_question: nil)}

  def handle_event("disconnect-integration", %{"kind" => kind}, socket)
      when kind in ["slack", "github"] do
    confirmed(socket, {"disconnect-#{kind}", kind}, fn socket ->
      key = String.to_existing_atom(kind)

      # Slack that was never switched on had only its tokens to remove.
      done =
        case {key, Integrations.read(key, socket.assigns.settings)} do
          {:slack, %{status: :off}} -> "The Slack tokens were removed."
          {:slack, _connected} -> "Slack is disconnected."
          {:github, _connected} -> "GitHub is disconnected."
        end

      finish_setup(socket, IntegrationSetup.disconnect(key), done)
    end)
  end

  def handle_event("delete-webhook-credential", %{"name" => name}, socket)
      when is_binary(name) do
    confirmed(socket, {"delete-webhook-credential", name}, fn socket ->
      case IntegrationSetup.delete_webhook_credential(name) do
        {:error, :credential_in_use} ->
          assign(socket,
            setup_notice: nil,
            setup_failure:
              "#{name} is in use by #{credential_users(socket, name)}. " <>
                "Change or remove that source first, then delete the credential."
          )

        result ->
          finish_setup(socket, result, "Signing credential #{name} was deleted.")
      end
    end)
  end

  def handle_event("retry-github-onboarding", %{"repository" => ref}, socket)
      when is_binary(ref) do
    # Success shows on the row itself, which turns to "Setting up".
    case IntegrationSetup.retry_github_onboarding(ref) do
      {:ok, _snapshot} ->
        {:noreply, socket |> assign(repository_notice: nil) |> refresh(true)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(repository_notice: {:list, :error, retry_error(reason)})
         |> refresh(true)}
    end
  end

  # A repository whose import stopped half-way is found among what the GitHub
  # App reaches and added the way the picker adds it.
  def handle_event("add-repository-again", %{"repository" => ref}, socket)
      when is_binary(ref) do
    %{actions: actions} = Endpoint.config(:control_plane)

    notice =
      with {:ok, discovered} <- actions.github_repositories.(),
           {:ok, result} <- IntegrationSetup.add_github_repository_again(ref, discovered) do
        {:list, import_tone(result), import_message(result, default_environment())}
      else
        {:error, reason} -> {:list, :error, add_again_error(reason)}
      end

    {:noreply, socket |> assign(repository_notice: notice) |> refresh(true)}
  end

  # Only the question's own button refreshes; one never asked about only
  # asks. A refresh that cannot run says why on the list.
  def handle_event(
        "refresh-knowledge",
        %{"repository" => ref},
        %{assigns: %{settings_confirm: {"refresh-knowledge", ref}}} = socket
      ) do
    name = socket.assigns.knowledge_question && socket.assigns.knowledge_question.name

    notice =
      case RepositoryKnowledge.refresh(ref, @actor_ref) do
        {:ok, :requested} ->
          {:list, :success, "Ryker is reading #{name || ref} again to rewrite its knowledge."}

        {:ok, :already_writing} ->
          {:list, :success, "Ryker is already rewriting the knowledge of #{name || ref}."}

        {:error, reason} ->
          {:list, :error, refresh_error(reason)}
      end

    {:noreply,
     socket
     |> assign(settings_confirm: nil, knowledge_question: nil, repository_notice: notice)
     |> refresh(true)}
  end

  def handle_event("refresh-knowledge", %{"repository" => ref}, socket) when is_binary(ref),
    do: {:noreply, ask_refresh_knowledge(socket, ref)}

  # Only the question's own button removes; a removal that was never asked
  # about only asks. One that is refused keeps its question open and says why.
  def handle_event(
        "remove-repository",
        %{"repository" => ref},
        %{assigns: %{settings_confirm: {"remove-repository", ref}}} = socket
      ) do
    case IntegrationSetup.remove_repository(ref) do
      # A removed repository's page is gone, so its removal returns to the
      # list, which says what was removed.
      {:ok, %{repository: repository}} ->
        socket =
          assign(socket,
            settings_confirm: nil,
            repository_question: nil,
            repository_notice:
              {:list, :success,
               "Removed #{repository.github_repository || ref}. Its past requests stay in Activity."}
          )

        {:noreply,
         if(socket.assigns.path == "/repositories",
           do: refresh(socket, true),
           else: push_patch(socket, to: "/repositories")
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           repository_question:
             socket.assigns.repository_question &&
               %{socket.assigns.repository_question | error: remove_error(reason)}
         )}
    end
  end

  def handle_event("remove-repository", %{"repository" => ref}, socket) when is_binary(ref),
    do: {:noreply, ask_remove_repository(socket, ref)}

  # A heavy body is prepared when the reader opens it and stays prepared while
  # they read: a refresh that closed the prompt they were halfway through would
  # make the page unusable during exactly the work it exists to explain.
  def handle_event("disclose", %{"artifact" => id}, socket)
      when is_binary(id) and byte_size(id) <= 256 do
    if MapSet.member?(socket.assigns.disclosed, id) do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:disclosed, MapSet.put(socket.assigns.disclosed, id))
       |> refresh()}
    end
  end

  def handle_event("disclose", _params, socket), do: {:noreply, socket}

  # After the index composer's first message is durable, the browser asks to
  # open the conversation its form was bound to. This is navigation only: the
  # id is validated as an identity, and the page shows whatever is retained
  # under it, which is nothing if the send never happened.
  def handle_event("open-conversation", %{"id" => id}, socket) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:noreply, push_patch(socket, to: "/conversations/#{id}")}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("open-conversation", _params, socket), do: {:noreply, socket}

  def handle_event("search-activity", params, socket) do
    params =
      Map.merge(
        Map.take(
          UsageProjection.link_params(socket.assigns.params),
          ~w(filter repository state conversation thread transport) ++
            UsageProjection.filter_keys()
        ),
        Map.take(UsageProjection.link_params(params), ~w(q mode))
      )

    patch_path = socket.assigns.path <> "?" <> URI.encode_query(params)
    {:noreply, push_patch(socket, to: patch_path, replace: true)}
  end

  # Every other list's search form searches as you type, the way Activity's
  # does: the page is patched to the form's own fields, which hold the view it
  # searches within. A form only ever patches the page it is on.
  def handle_event("search-page", %{"path" => form_path} = params, socket)
      when is_binary(form_path) do
    {path, fragment} =
      case String.split(form_path, "#", parts: 2) do
        [path, fragment] -> {path, "#" <> fragment}
        [path] -> {path, ""}
      end

    if path == socket.assigns.path do
      query =
        for {name, value} <- params,
            name not in ["path", "_target"],
            is_binary(value) and value != "" and byte_size(value) <= 512,
            into: %{},
            do: {name, value}

      query = if query == %{}, do: "", else: "?" <> URI.encode_query(query)
      {:noreply, push_patch(socket, to: path <> query <> fragment, replace: true)}
    else
      {:noreply, socket}
    end
  end

  # The filter menu is view state only: "fields" lists what can be added, a
  # key opens that filter's values, and choosing again closes it.
  def handle_event("filter-menu", %{"key" => key}, socket)
      when is_binary(key) and byte_size(key) <= 64 do
    menu =
      cond do
        socket.assigns.filter_menu == key -> nil
        key == "fields" or key in RequestFilters.keys() -> key
        true -> nil
      end

    {:noreply, assign(socket, :filter_menu, menu)}
  end

  def handle_event("filter-menu", _params, socket), do: {:noreply, socket}

  def handle_event("filter-menu-close", _params, socket),
    do: {:noreply, assign(socket, :filter_menu, nil)}

  # The value travels as "choice": LiveView's client overwrites a clicked
  # element's "value" with the button's own, which is empty.
  def handle_event("set-filter", %{"key" => key, "choice" => choice}, socket),
    do: patch_filters(socket, RequestFilters.set(socket.assigns.params, key, choice))

  def handle_event("remove-filter", %{"key" => key}, socket),
    do: patch_filters(socket, RequestFilters.remove(socket.assigns.params, key))

  # One older page of the open conversation. The request names the boundary
  # it expects to extend; anything else is a trigger that fired twice, a retry
  # of a page that already landed, or a request from a conversation this view
  # no longer shows, and each of those is answered, never loaded.
  # Filtering the conversation list is a reading aid over what is already
  # loaded; nothing is fetched or written.
  def handle_event("filter-conversations", %{"q" => query}, socket),
    do: {:noreply, assign(socket, :lab_filter, String.slice(query, 0, 200))}

  # A conversation's environment is its own choice, made under its message
  # box the way a channel's is made on its page: its messages from now on run
  # there, "" is no environment, and a small Saved says it took. A choice the
  # conversation cannot take (the environment is gone) leaves the choice
  # saying what is true now.
  def handle_event("select-conversation-environment", %{"environment" => environment}, socket)
      when is_binary(environment) and socket.assigns.native == :lab and
             is_map(socket.assigns.lab) do
    conversation_id = socket.assigns.lab.conversation_id
    choice = if environment == "", do: nil, else: environment

    case ConversationLab.select_environment(conversation_id, choice) do
      {:ok, environment_ref} ->
        {:noreply,
         assign(socket,
           lab_environment: environment_ref,
           lab_environment_saved: System.unique_integer([:positive])
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           lab_environment: conversation_environment(conversation_id),
           lab_environments: chat_environments(),
           lab_environment_saved: nil
         )}
    end
  end

  def handle_event("select-conversation-environment", _params, socket), do: {:noreply, socket}

  def handle_event("load-older", %{"conversation" => id, "before" => before}, socket)
      when is_binary(id) and is_binary(before) do
    case socket.assigns.lab_window do
      %{conversation_id: ^id, before: ^before} when socket.assigns.native == :lab ->
        load_older_page(socket)

      _stale_or_repeated ->
        {:reply, %{"status" => "ignored"}, socket}
    end
  end

  def handle_event("load-older", _params, socket),
    do: {:reply, %{"status" => "ignored"}, socket}

  defp lab_reaction_action("add"), do: {:ok, :add}
  defp lab_reaction_action("remove"), do: {:ok, :remove}
  defp lab_reaction_action(_action), do: {:error, :invalid_reaction}

  defp lab_mutation_result(socket, kind, id, {:ok, _accepted}) do
    socket = push_event(socket, "lab-action-accepted", %{kind: kind, id: id})
    {:noreply, refresh(socket, true)}
  end

  defp lab_mutation_result(socket, kind, id, {:error, reason}) do
    {:noreply,
     push_event(socket, "lab-action-rejected", %{
       kind: kind,
       id: id,
       reason: lab_mutation_reason(reason)
     })}
  end

  defp lab_mutation_reason(:unauthorized), do: "unauthorized"
  defp lab_mutation_reason(:invalid_reaction), do: "invalid"
  defp lab_mutation_reason({:invalid_conversation_lab, _field}), do: "invalid"
  defp lab_mutation_reason(_reason), do: "conflict"

  defp patch_filters(socket, params) do
    query = URI.encode_query(params)
    path = if query == "", do: socket.assigns.path, else: socket.assigns.path <> "?" <> query
    {:noreply, socket |> assign(:filter_menu, nil) |> push_patch(to: path)}
  end

  # The setup count is read first because what the shell listens to depends on
  # it, and the page listens before it reads. Working out what to listen to
  # changes nothing until it has all been worked out, so a failure there leaves
  # the page listening to what it did.
  defp refresh(socket, reset \\ false) do
    socket
    |> assign(:setup_progress, SettingsView.setup_progress())
    |> listen()
    |> read_page(reset)
  rescue
    error -> projection_failed(socket, error.__struct__, __STACKTRACE__)
  catch
    :throw, {:projection_unavailable, source} -> projection_failed(socket, source, [])
  end

  # A failed read keeps what the page now listens to, so the page still hears
  # the change that lets the read succeed.
  defp read_page(socket, reset) do
    socket
    |> load_page(Endpoint.config(:control_plane), reset)
    |> assign(unavailable: false, refresh_failures: 0, observed_at: DateTime.utc_now())
  rescue
    error -> projection_failed(socket, error.__struct__, __STACKTRACE__)
  catch
    :throw, {:projection_unavailable, source} -> projection_failed(socket, source, [])
  end

  defp projection_failed(socket, category, stack) do
    location =
      case List.first(stack) do
        {module, function, arity, _} ->
          "#{inspect(module)}.#{function}/#{if is_integer(arity), do: arity, else: length(arity)}"

        _ ->
          "not_recorded"
      end

    # Never log exception messages, arguments, route parameters, or database payloads.
    Logger.warning(
      "Control-plane projection unavailable category=#{inspect(category)} page=#{socket.assigns.native || :secondary} location=#{location}"
    )

    failures = min(socket.assigns.refresh_failures + 1, 6)

    # The one reload that is not an announcement: a page that could not be
    # read is tried again, backing off, until it can.
    socket
    |> assign(unavailable: true, refresh_failures: failures)
    |> schedule_reload(min(250 * Integer.pow(2, failures), 15_000))
  end

  defp load_page(%{assigns: %{path: path}} = socket, options, reset)
       when path in ["/", "/activity"] do
    activity = options.projection.activity.(socket.assigns.params)
    schedules = options.projection.schedules.(%{"status" => "active"}) |> Enum.take(4)

    socket
    |> assign(
      native: :activity,
      page_title: "Activity",
      activity: Map.delete(activity, :items),
      filter_values:
        if(reset,
          do:
            Activity.conversation_filter_options() ++
              options.projection.usage_filter_options.(),
          else: socket.assigns.filter_values
        ),
      overview: options.projection.overview.(),
      schedules: schedules
    )
    |> update_activity(activity.items, reset)
  end

  defp load_page(socket, options, _reset) do
    segments = String.split(socket.assigns.path, "/", trim: true)

    case settings_route(segments, socket.assigns.params) do
      {section, form} -> load_settings(socket, options, section, form)
      nil -> load_detail(socket, options, segments)
    end
  end

  # Each list with a page of one form: the list's address, the settings page
  # it is on and the kind of form. `<list>/new` adds one and `<list>/<key>/edit`
  # edits one; the router lets through only the ones that exist.
  @form_lists %{
    ["environments"] => {:environments, :environment},
    ["settings", "prices"] => {:pricing, :pricing},
    ["integrations", "emisar"] => {:emisar, :emisar},
    ["integrations", "webhooks", "credentials"] => {:webhooks, :webhook_credential},
    ["integrations", "webhooks", "sources"] => {:webhooks, :webhooks}
  }

  @doc false
  # A settings page, or a page of one form on it: {section, form}, where form
  # is nil or {kind, key}, key nil for a new one. A key comes from the route's
  # decoded parameters, never from the raw path.
  def settings_route(segments, params) do
    case Map.fetch(@settings_pages, segments) do
      {:ok, section} -> {section, nil}
      :error -> segments |> Enum.reverse() |> form_route(params)
    end
  end

  defp form_route(["new" | list], _params), do: form_list(Enum.reverse(list), nil)

  defp form_route(["edit", _key | list], params),
    do: form_list(Enum.reverse(list), params["ref"] || params["item"])

  defp form_route(_segments, _params), do: nil

  defp form_list(list, key) do
    case Map.fetch(@form_lists, list) do
      {:ok, {section, kind}} -> {section, {kind, key}}
      :error -> nil
    end
  end

  defp load_detail(socket, options, ["timeline", _ref | _rest]) do
    disclosed =
      %{"disclosed" => MapSet.to_list(socket.assigns.disclosed)}
      |> Map.merge(Map.take(socket.assigns.params, ["events"]))

    with {:ok, episode} <- options.projection.episode.(socket.assigns.params["ref"], disclosed),
         {:ok, timeline} <-
           options.projection.model_timeline.(
             socket.assigns.params["ref"],
             Map.merge(
               disclosed,
               Map.take(socket.assigns.params, ["attempt", "responses_page", "calls"])
             )
           ) do
      assign(socket,
        native: :episode,
        page_title: "Timeline",
        episode: episode,
        timeline: timeline,
        requests: nil
      )
    else
      :not_found -> load_unassigned_input(socket, options)
    end
  end

  # The global editor, then the channels that add their own instructions and
  # the preferences and guidance people saved from conversations.
  defp load_detail(socket, options, ["instructions"]) do
    {:ok, view} = options.projection.instructions.(:global)

    saved =
      options.projection.behaviors.(
        [:preference, :guidance],
        Map.take(socket.assigns.params, ["show", "view", "page"])
      )

    assign(socket,
      native: :instructions,
      page_title: "Instructions",
      page_description: ConfigurationGuide.description(:instructions),
      page_back: nil,
      page_state: nil,
      page_title_href: nil,
      body_lead: "",
      body:
        BehaviorPage.instructions(%{__changed__: nil, channels: view.channels, saved: saved})
        |> Safe.to_iodata()
        |> IO.iodata_to_binary(),
      instructions: view,
      instruction_scope: :global,
      save_instructions: options.actions.save_instructions
    )
  end

  # The route's decoded params name the channel; the raw path segments would
  # hand a percent-encoded link to the projection undecoded and find nothing.
  defp load_detail(socket, options, ["channels", _workspace, _channel]) do
    %{"workspace" => workspace, "channel" => channel} = socket.assigns.params
    params = Map.take(socket.assigns.params, ChannelDetail.query_keys())

    with {:ok, snapshot} <- options.projection.channel.(workspace, channel, params),
         {:ok, view} <- options.projection.instructions.({:channel, workspace, channel}) do
      assign(socket,
        native: :instructions,
        page_title: ChannelPage.title(snapshot),
        page_description: ChannelPage.description(snapshot),
        page_back: {"All channels", "/channels"},
        page_state: ChannelPage.header_state(snapshot),
        page_title_href: ChannelPage.slack_url(snapshot),
        body_lead:
          ChannelPage.lead(%{
            __changed__: nil,
            view: snapshot,
            notice: socket.assigns.channel_notice
          })
          |> Safe.to_iodata()
          |> IO.iodata_to_binary(),
        body:
          ChannelPage.render(%{__changed__: nil, view: snapshot})
          |> Safe.to_iodata()
          |> IO.iodata_to_binary(),
        instructions: view,
        instruction_scope: {:channel, workspace, channel},
        save_instructions: options.actions.save_instructions
      )
    else
      _ -> load_snapshot(socket, options)
    end
  end

  # The index is an empty draft: the same view as an open conversation, bound
  # to an identity that has no record yet. The composer is a phx-update=ignore
  # form, so the identity the browser posts to is the one its first render
  # carried, which the server cannot see again after a reconnect. Following the
  # first send is therefore the client's job ("open-conversation" below).
  defp load_detail(socket, options, ["conversations"]) do
    case LabControls.snapshot(socket.assigns.lab_draft_id, options) do
      {:ok, snapshot, token} ->
        socket
        |> load_conversation(Map.put(snapshot, :draft, true), token, options)
        |> assign(lab_announcement: "")

      {:error, _} ->
        throw({:projection_unavailable, :lab})
    end
  end

  defp load_detail(socket, options, ["conversations", _id]) do
    case LabControls.snapshot(socket.assigns.params["id"], options) do
      {:ok, snapshot, token} ->
        load_conversation(socket, snapshot, token, options)

      {:error, :path_ref} ->
        assign(socket, native: :not_found, page_status: 404, page_title: "Not found")

      {:error, _} ->
        throw({:projection_unavailable, :lab})
    end
  end

  # Add repositories lists what the GitHub App reaches once the page is live;
  # a redraw does not ask GitHub again.
  defp load_detail(socket, options, ["repositories", "new"]) do
    socket = load_snapshot(socket, options)

    if socket.assigns.github_repository_discovery == :idle and connected?(socket) and
         match?({:ok, %{github_connection: :ready}}, socket.assigns.settings),
       do: discover_github_repositories(socket, options),
       else: socket
  end

  defp load_detail(socket, options, _segments), do: load_snapshot(socket, options)

  # GitHub can take seconds to list every installation's repositories, so the
  # page stays live while it answers.
  defp discover_github_repositories(socket, options) do
    discover = options.actions.github_repositories

    socket
    |> assign(:github_repository_discovery, :loading)
    |> start_async(:github_repositories, discover)
  end

  # Setup, the environments, the integrations and the installation settings
  # are one native page family, with a page of its own for each form that adds
  # or edits one thing on them; the route map lets through only these.
  defp load_settings(socket, options, section, form) do
    settings = options.projection.settings.()

    assign(socket,
      native: :settings,
      page_title: SettingsPage.title(section, form, settings),
      settings: settings,
      settings_commands: settings_commands(options),
      settings_section: section,
      settings_form: form,
      # Asked for with a link, so a reload shows it again; read afresh with
      # the page, it never posts or records anything.
      weekly_preview:
        if(
          section == :report and is_nil(form) and match?({:ok, _view}, settings) and
            socket.assigns.params["preview"] == "week",
          do: options.projection.weekly_report_preview.()
        ),
      body:
        if(section == :system and is_nil(form),
          do: configuration_evidence(options, settings),
          else: ""
        )
    )
  end

  defp load_conversation(socket, snapshot, token, options) do
    reset =
      is_nil(socket.assigns.lab) or
        socket.assigns.lab.conversation_id != snapshot.conversation_id

    socket
    |> sync_lab_window(snapshot, reset, options)
    |> assign(
      native: :lab,
      page_title: "Conversations",
      lab: snapshot,
      lab_announcement:
        if(reset,
          do: "",
          else:
            LabPage.announcement(socket.assigns.lab, snapshot) ||
              socket.assigns.lab_announcement
        ),
      lab_token: token,
      lab_items: options.projection.lab_index.(),
      lab_environment: conversation_environment(snapshot.conversation_id),
      lab_environments: chat_environments(),
      readiness: options.projection.readiness.()
    )
  end

  # Chat's environment choices, from the settings; none before the settings
  # exist, when the head says only where the conversation works.
  defp chat_environments do
    case Settings.fetch() do
      {:ok, snapshot} -> LabPage.environment_choices(snapshot)
      {:error, :settings_not_initialized} -> []
    end
  end

  # The conversation's environment: chosen for it, recorded when it started,
  # or the default for one that has not started yet.
  defp conversation_environment(conversation_id) do
    case ConversationLab.environment(conversation_id) do
      {:ok, environment_ref} -> environment_ref
      {:error, _reason} -> nil
    end
  end

  defp settings_commands(options) do
    Map.take(options.actions, [
      :delete_settings_item,
      :initialize_settings,
      :preview_retention,
      :preview_webhook,
      :put_settings_item,
      :save_settings,
      :send_weekly_report_preview
    ])
    |> Map.new(fn {key, callback} -> {command_name(key), callback} end)
  end

  defp command_name(:delete_settings_item), do: :delete_item
  defp command_name(:initialize_settings), do: :initialize
  defp command_name(:preview_retention), do: :preview_retention
  defp command_name(:preview_webhook), do: :preview_webhook
  defp command_name(:put_settings_item), do: :put_item
  defp command_name(:save_settings), do: :save
  defp command_name(:send_weekly_report_preview), do: :send_weekly_report_preview

  defp initialize_settings(socket) do
    socket.assigns.settings_commands.initialize.()
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :settings_unavailable}
  end

  defp initialize_error(:settings_forbidden),
    do: "This console is not allowed to create settings."

  defp initialize_error(_reason),
    do: "Settings could not be created. Check that the database is reachable, then try again."

  defp finish_setup(socket, {:ok, _result}, message) do
    socket
    |> refresh_settings()
    |> assign(setup_notice: message, setup_failure: nil, setup_reveal: nil)
  end

  defp finish_setup(socket, {:error, reason}, _message), do: failed(socket, reason)

  # A refusal is said in the error tone, never in the tone of a success.
  defp failed(socket, reason),
    do:
      assign(socket,
        setup_notice: nil,
        setup_failure: IntegrationErrors.message(reason),
        setup_reveal: nil
      )

  # The question is read from the repository's row as the list shows it now.
  defp ask_remove_repository(socket, ref) do
    %{projection: projection} = Endpoint.config(:control_plane)

    case projection.repository.(ref) do
      {:ok, %{configured: %{}} = item} ->
        assign(socket,
          settings_confirm: {"remove-repository", ref},
          repository_question: Map.put(RepositoriesPage.removal(item), :error, nil),
          repository_notice: nil
        )

      _gone ->
        socket
        |> assign(repository_notice: {:list, :error, remove_error(:repository_not_found)})
        |> refresh(true)
    end
  end

  defp ask_refresh_knowledge(socket, ref) do
    %{projection: projection} = Endpoint.config(:control_plane)

    case projection.repository.(ref) do
      {:ok, %{configured: %{}} = item} ->
        assign(socket,
          settings_confirm: {"refresh-knowledge", ref},
          knowledge_question:
            item
            |> RepositoriesPage.refresh_question()
            |> Map.put(:name, RepositoriesPage.name(item)),
          repository_notice: nil
        )

      _gone ->
        socket
        |> assign(repository_notice: {:list, :error, refresh_error(:repository_not_found)})
        |> refresh(true)
    end
  end

  defp confirmed(%{assigns: %{settings_confirm: asked}} = socket, asked, run),
    do: {:noreply, socket |> assign(:settings_confirm, nil) |> run.()}

  defp confirmed(socket, question, _run),
    do: {:noreply, assign(socket, settings_confirm: question, setup_notice: nil)}

  defp credential_users(%{assigns: %{settings: {:ok, view}}}, name) do
    case for(source <- view.snapshot.webhook_sources, source.secret_name == name, do: source.name) do
      [] -> "a webhook source"
      sources -> Enum.join(sources, ", ")
    end
  end

  defp credential_users(_socket, _name), do: "a webhook source"

  # The modal's button says what the button that asked said: Forget, Delete,
  # Pause. It is the page's own word, bounded; anything else reads Confirm.
  defp button_label(label) when is_binary(label) and byte_size(label) in 1..60,
    do: String.trim(label)

  defp button_label(_label), do: "Confirm"

  # A form that did what it was for returns to its list, carrying what it did.
  defp return_with(socket, path, notice),
    do: socket |> assign(carried_notice: notice) |> push_patch(to: path)

  # Connecting says where the account is used now, by environment name.
  defp emisar_connected({:ok, %{environments: refs}}) do
    names =
      case SettingsView.fetch() do
        {:ok, view} ->
          Enum.map(
            refs,
            &(Environments.find(view.snapshot, &1) || %{display_name: &1}).display_name
          )

        {:error, _unavailable} ->
          refs
      end

    Integrations.emisar_connected(names)
  end

  # A removal at the revision the page shows. A removed environment's page is
  # gone, so it returns to the list; one the settings refuse names who still
  # chooses the environment.
  defp delete_environment(socket, ref) do
    with {:ok, view} <- socket.assigns.settings,
         %{} = environment <- Environments.find(view.snapshot, ref) do
      case Settings.delete_environment(ref, view.revision, Settings.actor()) do
        {:ok, _snapshot} ->
          socket
          |> refresh_settings()
          |> assign(setup_failure: nil)
          |> return_with("/environments", "#{environment.display_name} was removed.")

        {:error, reason} ->
          environment_refused(socket, environment, reason)
      end
    else
      _missing -> failed(socket, :environment_not_found)
    end
  end

  defp environment_refused(socket, environment, {:invalid_settings, errors} = reason) do
    case Keyword.get(errors, :ref) do
      {:referenced, users} ->
        assign(socket,
          setup_notice: nil,
          setup_failure: Environments.refusal(environment.display_name, users)
        )

      _other ->
        failed(socket, reason)
    end
  end

  defp environment_refused(socket, _environment, reason), do: failed(socket, reason)

  defp refresh_settings(socket), do: assign(socket, :settings, SettingsView.fetch())

  # A change redraws the channel's welcome in Slack the way a save made there
  # does (until 2026-09-26 the card kept naming the old environment). The
  # redraw runs on Slack's own task and reports back here, so a slow Slack
  # never holds up the save. What the page says is the small saved mark
  # beside the choice, never a banner (Andrew, 2026-09-27: "edit confirmation
  # can be way more subtle"); a refusal is said at the choice, and stays.
  defp change_channel_setting(
         socket,
         %{"workspace" => workspace, "channel" => channel} = params,
         name
       )
       when is_binary(workspace) and is_binary(channel) do
    key = System.unique_integer([:positive])

    {notice, pending} =
      case save_channel_setting(workspace, channel, name, params) do
        {:ok, %{status: :unchanged}} ->
          {{:saved, name, key, nil}, nil}

        {:ok, %{status: :saved}} ->
          %{actions: actions} = Endpoint.config(:control_plane)

          case actions.redraw_channel_welcome.(workspace, channel) do
            :ok -> {{:saved, name, key, nil}, {workspace, channel, name, key}}
            {:error, reason} -> {{:saved, name, key, welcome_not_redrawn(reason)}, nil}
          end

        {:error, reason} ->
          {{:error, name, channel_setting_error(reason)}, nil}
      end

    {:noreply,
     socket |> assign(channel_notice: notice, welcome_pending: pending) |> refresh(true)}
  end

  defp change_channel_setting(socket, _params, _name), do: {:noreply, socket}

  # Slack takes Ryker out and the page says so. What it did and learned in
  # the channel stays.
  defp leave_channel(socket, ref) do
    %{actions: actions} = Endpoint.config(:control_plane)

    with [workspace, channel] <- String.split(ref, "/", parts: 2),
         {:ok, _result} <- actions.leave_channel.(workspace, channel) do
      socket
      |> assign(
        setup_notice:
          "Ryker left the channel. Invite it back with /invite in Slack whenever you need it there.",
        setup_failure: nil
      )
      |> refresh(true)
    else
      {:error, reason} -> assign(socket, setup_notice: nil, setup_failure: leave_error(reason))
      _malformed -> assign(socket, setup_notice: nil, setup_failure: leave_error(:malformed))
    end
  end

  defp leave_error(:slack_not_running),
    do:
      "Slack is not connected, so Ryker could not leave the channel. Connect Slack, then try again."

  defp leave_error({:slack_api_error, "cant_leave_general"}),
    do: "Slack does not let anyone leave the workspace's general channel."

  defp leave_error({:slack_api_error, "missing_scope"}),
    do:
      "The Slack app is missing the permission to leave channels. Update it from the manifest on the Slack page, then try again."

  defp leave_error(_reason),
    do: "Slack did not take Ryker out of the channel. Try again in a moment."

  defp save_channel_setting(workspace, channel, "environment", %{"environment" => ref})
       when is_binary(ref) do
    choice = if ref == "", do: nil, else: ref
    ChannelConfigurations.select_environment(workspace, channel, choice, @actor_ref)
  end

  defp save_channel_setting(workspace, channel, name, params)
       when name in ["participation", "alert_policy"] do
    change =
      if name == "participation",
        do: &ChannelConfigurations.change_participation/1,
        else: &ChannelConfigurations.change_alert_policy/1

    with {:ok, value} <- channel_setting_value(name, params[name]),
         {revision, ""} <- Integer.parse(to_string(params["revision"])) do
      change.(%{
        String.to_existing_atom(name) => value,
        actor_ref: @actor_ref,
        channel_ref: channel,
        configuration_ref: params["configuration"],
        event_ref: "control-plane:channel:" <> Ecto.UUID.generate(),
        expected_revision: revision,
        occurred_at: DateTime.utc_now(),
        workspace_ref: workspace
      })
    else
      _invalid -> {:error, :invalid_choice}
    end
  end

  defp save_channel_setting(_workspace, _channel, _name, _params),
    do: {:error, :invalid_choice}

  # The values Slack's setup offers, and nothing else.
  @channel_setting_values %{
    "participation" => %{"mentions" => :mentions, "proactive" => :proactive, "shadow" => :shadow},
    "alert_policy" => %{"reply" => :reply, "offer" => :offer, "automatic" => :automatic}
  }

  defp channel_setting_value(name, value) do
    case @channel_setting_values |> Map.fetch!(name) |> Map.fetch(value) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :invalid_choice}
    end
  end

  defp welcome_not_redrawn(:slack_not_running),
    do:
      "Slack is not connected, so the welcome message in the channel still shows the old setting."

  defp welcome_not_redrawn(:timeout),
    do: "Slack did not answer in time, so the welcome message may still show the old setting."

  defp welcome_not_redrawn(_refused),
    do: "Ryker could not update its welcome message in Slack, so it still shows the old setting."

  defp channel_setting_error(:configuration_revision_stale),
    do:
      "This channel's settings changed in Slack meanwhile. The page shows them now; choose again."

  defp channel_setting_error(:configuration_not_found),
    do: "Ryker has no settings for this channel yet. Invite Ryker to the channel first."

  defp channel_setting_error(:configuration_membership_not_joined),
    do: "Ryker is not in this channel now. Invite it back to change how it takes part."

  defp channel_setting_error(:environment_not_found),
    do: "That environment no longer exists. Choose another one."

  defp channel_setting_error(_reason),
    do: "This change could not be saved. Reload the page and try again."

  # What an import did, said where the person who asked is looking. A partial
  # failure names the repositories that did not make it.
  defp import_tone(%{added: [], already_present: [], failed: []}), do: :info
  defp import_tone(%{failed: []}), do: :success
  defp import_tone(%{added: [], already_present: []}), do: :error
  defp import_tone(_partial), do: :warning

  defp import_message(%{added: [], already_present: [], failed: []}, _environment),
    do: "No repositories were selected."

  # An added repository joins the default environment, so the message says
  # where it can be used at once.
  defp import_message(%{added: added, already_present: present, failed: failed}, environment) do
    joined = if environment, do: " to the #{environment} environment", else: ""

    [
      case length(added) do
        0 -> "No repositories were added."
        1 -> "Added 1 repository#{joined}."
        count -> "Added #{count} repositories#{joined}."
      end,
      case length(present) do
        0 -> nil
        1 -> "1 was already added."
        count -> "#{count} were already added."
      end,
      if(failed != [],
        do: "Could not add " <> Enum.map_join(failed, ", ", &to_string(&1.repository)) <> "."
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp default_environment do
    with {:ok, snapshot} <- Settings.fetch(),
         %{display_name: name} <- Settings.Environment.default(snapshot) do
      name
    else
      _none -> nil
    end
  end

  defp retry_error(:github_access_unavailable),
    do:
      "Setup cannot retry while GitHub access is unavailable. Give the Ryker GitHub App access to the repository first."

  defp retry_error(:repository_not_found), do: "That repository is no longer added."

  defp retry_error(_reason),
    do: "Setup could not be retried. Reload the page and try again."

  defp add_again_error({:github_repository_unreachable, name}),
    do:
      "The GitHub App cannot reach #{name}. Give the app access to it on GitHub, then add it " <>
        "again."

  defp add_again_error(:repository_not_found), do: "That repository is no longer added."
  defp add_again_error(reason), do: IntegrationErrors.message(reason)

  defp refresh_error(:repository_not_found), do: "That repository is no longer added."

  defp refresh_error(:repository_not_ready),
    do: "Knowledge is written once the repository's setup has finished."

  defp refresh_error(reason)
       when reason in [:github_access_unavailable, :repository_binding_missing],
       do:
         "Ryker cannot reach this repository on GitHub. Give the Ryker GitHub App access " <>
           "to it, then refresh."

  defp refresh_error(_reason),
    do: "The knowledge could not be refreshed. Reload the page and try again."

  defp remove_error(:repository_not_found), do: "That repository is no longer added."

  defp remove_error({:environment_left_read_only, environment}),
    do:
      "Work in #{environment} can change only this repository. Make another of its " <>
        "repositories read and write on the Environments page, then remove this one."

  defp remove_error(_reason),
    do: "The repository could not be removed. Reload the page and try again."

  # Read-only evidence of what the running process assembled. It is rendered
  # from the application environment the runtime published, not from settings,
  # so a saved-but-unapplied revision is visibly not in it. The integrations in
  # it read the same state as their own pages; settings that cannot be read
  # show no page at all, so there is nothing to render them into.
  defp configuration_evidence(options, {:ok, _view}),
    do: options.projection.running_system.() |> RunningSystem.html()

  defp configuration_evidence(_options, _unavailable), do: ""

  # A secondary page is prepared whole by Pages from the path as the browser
  # sent it; a 503 keeps the last observed page on screen rather than
  # replacing it with an error page that would read as the record's state.
  defp load_snapshot(socket, options) do
    segments = String.split(socket.assigns.path, "/", trim: true)
    page = Pages.page(segments, socket.assigns.params, options)
    if page.status >= 500, do: throw({:projection_unavailable, :secondary})

    assign(socket,
      native: nil,
      page_status: page.status,
      body: page.body,
      page_title: page.title,
      page_description: page.description,
      page_action: Map.get(page, :action),
      page_state: Map.get(page, :state),
      page_title_href: Map.get(page, :title_href),
      page_back: Map.get(page, :back),
      settings: options.projection.settings.(),
      settings_commands: settings_commands(options)
    )
  end

  defp load_unassigned_input(
         %{assigns: %{params: %{"ref" => "ingress-input:" <> id}}} = socket,
         options
       ) do
    case options.projection.admission_request.(
           id,
           Map.put(
             socket.assigns.params,
             "disclosed",
             MapSet.to_list(socket.assigns.disclosed)
           )
         ) do
      {:ok, %{episode_ref: nil} = requests} ->
        assign(socket,
          native: :request,
          page_title: "Message",
          requests: requests
        )

      _ ->
        assign(socket, native: :not_found, page_status: 404, page_title: "Not found")
    end
  end

  defp load_unassigned_input(socket, _options),
    do: assign(socket, native: :not_found, page_status: 404, page_title: "Not found")

  defp update_activity(socket, items, true) do
    items = ActivityPage.with_days(items, socket.assigns.observed_at || DateTime.utc_now())

    socket
    |> stream(:activity, items, reset: true)
    |> assign(
      row_ids: Enum.map(items, &dom_id/1),
      row_days: Map.new(items, &{dom_id(&1), &1.day}),
      new_items: 0
    )
  end

  defp update_activity(socket, items, false) do
    current = socket.assigns.row_ids
    incoming = Enum.map(items, &dom_id/1)
    # Do not move existing rows beneath the reader. Removed rows must not remain actionable.
    socket = Enum.reduce(current -- incoming, socket, &stream_delete_by_dom_id(&2, :activity, &1))
    retained = Enum.filter(current, &(&1 in incoming))
    by_id = Map.new(items, &{dom_id(&1), &1})

    # Rows keep the day they were listed under, and each day's first shown
    # row its heading, until the reader shows the latest.
    kept =
      retained
      |> Enum.map(&{&1, Map.fetch!(by_id, &1)})
      |> ActivityPage.kept_days(
        Map.get(socket.assigns, :row_days, %{}),
        socket.assigns.observed_at || DateTime.utc_now()
      )

    socket
    |> stream(:activity, kept)
    |> assign(
      row_ids: retained,
      new_items: if(incoming == retained, do: 0, else: max(length(incoming -- current), 1))
    )
  end

  defp dom_id(item), do: "activity-#{item.kind}-#{item.id}"

  # A row is named by the logical message it shows, so an edit, a delete, a
  # retention prune or a delivery confirmation updates the row in place.
  defp lab_dom_id(message) do
    digest =
      :crypto.hash(:sha256, message[:identity] || "#{message.actor}:#{message.ref}")
      |> Base.encode16(case: :lower)

    "lab-message-" <> digest
  end

  # The loaded window of one conversation's transcript: which rows the client
  # holds, in transcript order, a digest of what each one last showed, and the
  # boundary for the next older page. Until 2026-09-13 every refresh deleted
  # any loaded row the latest snapshot did not repeat, so the history a reader
  # had scrolled up to vanished under them on the next reconcile. A refresh
  # now merges the latest page into the window; only opening a different
  # conversation resets it.
  defp sync_lab_window(socket, snapshot, true, _options) do
    history = lab_history_of(snapshot)
    progress = lab_progress_by_input(snapshot)

    socket
    |> stream(:lab_messages, snapshot.messages, reset: true)
    |> assign(
      :lab_window,
      lab_window_rows(
        %{
          before: history.before,
          conversation_id: snapshot.conversation_id,
          digests: %{},
          exhausted: history.exhausted,
          failed: false,
          page_size: history.page_size,
          rows: [],
          synced_at: DateTime.utc_now()
        },
        snapshot.messages,
        progress
      )
    )
  end

  # A refresh merges the latest page, then every row that changed since the
  # window last synced: an edit or reaction on a message the reader scrolled
  # up to is not on the latest page but must still land on its row. The
  # overlap behind `synced_at` covers the gap between the host clock and the
  # database clock; a row fetched twice with nothing changed is not patched.
  defp sync_lab_window(socket, snapshot, false, options) do
    window = socket.assigns.lab_window
    history = lab_history_of(snapshot)
    progress = lab_progress_by_input(snapshot)
    since = DateTime.add(window.synced_at, -10, :second)
    synced_at = DateTime.utc_now()

    socket =
      case lab_bridge(snapshot.messages, history, window, options) do
        {:merge, messages} ->
          merge_lab_rows(socket, messages, nil, progress)

        {:adopt, messages, history} ->
          socket
          |> stream(:lab_messages, [], reset: true)
          |> assign(:lab_window, %{
            window
            | before: history.before,
              digests: %{},
              exhausted: history.exhausted,
              failed: false,
              rows: []
          })
          |> merge_lab_rows(messages, nil, progress)
      end

    socket =
      case LabControls.changes(window.conversation_id, since, window.page_size, options) do
        {:ok, changed} -> merge_lab_rows(socket, changed, lab_window_floor(socket), progress)
        {:error, _reason} -> throw({:projection_unavailable, :lab})
      end

    assign(socket, :lab_window, %{socket.assigns.lab_window | synced_at: synced_at})
  end

  defp lab_window_floor(socket) do
    case socket.assigns.lab_window.rows do
      [{_dom_id, oldest} | _rest] -> oldest
      [] -> nil
    end
  end

  defp lab_history_of(snapshot) do
    Map.get(snapshot, :history) ||
      %{before: nil, exhausted: true, page_size: ConversationProjection.page_size()}
  end

  # The latest page must reach back to a row the window already holds before
  # it can be merged; otherwise more than a page arrived since the last
  # refresh and the rows between would be missing. Up to three older pages
  # bridge the gap. When even that is not enough, the window restarts from
  # what was fetched and the reader can scroll up to reload what it dropped.
  defp lab_bridge(messages, history, %{rows: []}, _options), do: {:adopt, messages, history}

  defp lab_bridge(messages, history, window, options) do
    {_dom_id, newest} = List.last(window.rows)
    lab_bridge(messages, history, newest, window, options, 3)
  end

  defp lab_bridge(messages, history, newest, window, options, budget) do
    overlapping? =
      history.exhausted or messages == [] or hd(messages).sort_key <= newest

    cond do
      overlapping? ->
        {:merge, messages}

      budget == 0 ->
        {:adopt, messages, history}

      true ->
        case LabControls.history(
               window.conversation_id,
               history.before,
               window.page_size,
               options
             ) do
          {:ok, page} ->
            lab_bridge(
              page.messages ++ messages,
              %{history | before: page.before, exhausted: page.exhausted},
              newest,
              window,
              options,
              budget - 1
            )

          {:error, _reason} ->
            throw({:projection_unavailable, :lab})
        end
    end
  end

  # Inserts or updates each message in the window without moving any row the
  # client already holds. A new row goes exactly where its sort key falls
  # among the loaded rows; an existing row is re-sent only when what it
  # shows has changed, so an untouched row is never patched at all. With a
  # `floor`, a new row older than the window's oldest row is left for paging:
  # inserting it at the top would hide the gap between it and the window.
  defp merge_lab_rows(socket, messages, floor, progress) do
    {socket, window} =
      Enum.reduce(messages, {socket, socket.assigns.lab_window}, fn message, {socket, window} ->
        merge_lab_row(socket, window, message, floor, progress)
      end)

    assign(socket, :lab_window, window)
  end

  defp merge_lab_row(socket, window, message, floor, progress) do
    dom_id = lab_dom_id(message)
    digest = lab_row_digest(message, progress)

    case Map.fetch(window.digests, dom_id) do
      {:ok, ^digest} ->
        {socket, window}

      {:ok, _changed} ->
        {stream_insert(socket, :lab_messages, message),
         %{window | digests: Map.put(window.digests, dom_id, digest)}}

      :error when is_tuple(floor) and message.sort_key < floor ->
        {socket, window}

      :error ->
        index = Enum.count(window.rows, fn {_id, key} -> key < message.sort_key end)
        at = if index == length(window.rows), do: -1, else: index

        {stream_insert(socket, :lab_messages, message, at: at),
         %{
           window
           | digests: Map.put(window.digests, dom_id, digest),
             rows: List.insert_at(window.rows, index, {dom_id, message.sort_key})
         }}
    end
  end

  defp lab_window_rows(window, messages, progress) do
    rows = Enum.map(messages, &{lab_dom_id(&1), &1.sort_key})

    digests =
      Map.new(messages, &{lab_dom_id(&1), lab_row_digest(&1, progress)})

    %{window | digests: digests, rows: rows}
  end

  defp lab_row_digest(message, progress) do
    visible_progress =
      progress
      |> Map.get(message[:native_input_id], [])
      |> Enum.map(&Map.take(&1, [:href, :id, :phase]))

    :crypto.hash(:sha256, :erlang.term_to_binary({message, visible_progress}))
  end

  defp lab_progress_by_input(snapshot) do
    snapshot
    |> Map.get(:admission_progress, [])
    |> Enum.group_by(& &1.native_input_id)
  end

  defp load_older_page(socket) do
    window = socket.assigns.lab_window
    options = Endpoint.config(:control_plane)
    progress = lab_progress_by_input(socket.assigns.lab)

    case LabControls.history(window.conversation_id, window.before, window.page_size, options) do
      {:ok, page} ->
        socket =
          socket
          |> assign(:lab_window, %{
            window
            | before: page.before,
              exhausted: page.exhausted,
              failed: false
          })
          |> merge_lab_rows(page.messages, nil, progress)

        {:reply, %{"status" => "loaded"}, socket}

      {:error, _reason} ->
        {:reply, %{"status" => "failed"}, assign(socket, :lab_window, %{window | failed: true})}
    end
  rescue
    error ->
      # Never log the exception body: it can carry query parameters.
      Logger.warning(
        "Conversation history page unavailable category=#{inspect(error.__struct__)}"
      )

      window = socket.assigns.lab_window
      {:reply, %{"status" => "failed"}, assign(socket, :lab_window, %{window | failed: true})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      class="ryker-app"
      id="ryker-shell"
      phx-hook="PreserveReadingState"
      data-connection-state={if @connected, do: "connected", else: "connecting"}
      data-updated-at={if @observed_at, do: DateTime.to_iso8601(@observed_at)}
    >
      <Navigation.sidebar path={@path} live={true} setup={@setup_progress} />
      <div class="app-workspace">
        <div class="mobile-navigation">
          <Navigation.mobile path={@path} live={true} setup={@setup_progress} />
        </div>
        <div class="connection-offline app-warning" role="status">
          Reconnecting… Your view will update automatically.
        </div>
        <div :if={@unavailable} class="app-warning" role="status">
          This view could not refresh. Showing the last observed state; execution continues independently.
          <button phx-click="refresh">Try again</button>
        </div>
        <main
          id="operator-page"
          class={if @native, do: "native-page", else: "page-surface"}
        >
          <PageHelp.panel path={@path} />
          <section :if={@native == :loading && @unavailable} class="document-unavailable">
            <h1>This view is temporarily unavailable</h1><p>
              Retry the view. No content from a different page is shown here.
            </p>
          </section>
          <ActivityPage.render
            :if={@native == :activity && @activity}
            activity={@activity}
            filter_menu={@filter_menu}
            filter_values={@filter_values}
            overview={@overview}
            schedules={@schedules}
            stream={@streams.activity}
            new_items={@new_items}
            params={@params}
            path={@path}
            now={@observed_at || DateTime.utc_now()}
          />
          <EpisodePage.render
            :if={@native == :episode}
            snapshot={@episode}
            params={@params}
            timeline={@timeline}
          />
          <LabPage.render
            :if={@native == :lab && @lab}
            snapshot={@lab}
            token={@lab_token}
            items={@lab_items}
            filter={@lab_filter}
            messages={@streams.lab_messages}
            history={@lab_window}
            announcement={@lab_announcement}
            readiness={@readiness}
            environments={@lab_environments}
            environment={@lab_environment}
            environment_saved={@lab_environment_saved}
            now={@observed_at || DateTime.utc_now()}
          />
          <SettingsPage.render
            :if={@native == :settings}
            view={@settings}
            commands={@settings_commands}
            body={@body}
            error={@settings_error}
            section={@settings_section}
            notice={@setup_notice}
            failure={@setup_failure}
            confirm={@settings_confirm}
            reveal={@setup_reveal}
            slack_members={@slack_members}
            form={@settings_form}
            params={@params}
            preview={@weekly_preview}
            preview_sent={@weekly_sent}
          />
          <div :if={@native == :instructions} class="secondary-page instructions-page">
            <Components.page_header
              title={@page_title}
              description={@page_description}
              back={@page_back}
              status={@page_state}
              title_href={@page_title_href}
              navigate
            />
            <Components.form_feedback
              :if={@setup_failure}
              message={@setup_failure}
              tone={:error}
              class="page-feedback"
            />
            <Components.form_feedback
              :if={@setup_notice}
              message={@setup_notice}
              tone={:success}
              class="page-feedback"
            />
            {Phoenix.HTML.raw(@body_lead)}
            <.live_component
              module={Ryker.ControlPlane.InstructionsEditor}
              id={"instructions-#{@instructions.setting.scope_ref}"}
              scope={@instruction_scope}
              view={@instructions}
              save={@save_instructions}
            />
            {Phoenix.HTML.raw(@body)}
          </div>
          <EpisodePage.message_page :if={@native == :request} view={@requests} />
          <section :if={@native == :not_found} class="document-unavailable">
            <h1>This record is unavailable</h1><p>
              It does not exist or is no longer available. Check the link, or start again from Activity.
            </p><.link navigate="/" class="ui-button secondary">Back to activity</.link>
          </section>
          <div :if={!@native} class="secondary-page">
            <Components.page_header
              title={@page_title}
              description={@page_description}
              back={@page_back}
              status={@page_state}
              title_href={@page_title_href}
              navigate
            >
              <:action :if={@page_action}>{Phoenix.HTML.raw(@page_action)}</:action>
              <:action :if={learning_switch?(@path, @params, @settings)}>
                <.live_component
                  module={Ryker.ControlPlane.LearningSwitch}
                  id="learning-switch"
                  view={elem(@settings, 1)}
                  commands={@settings_commands}
                  confirm={@settings_confirm}
                />
              </:action>
              <:action :if={
                @path == "/repositories/new" and
                  match?({:ok, %{github_connection: :ready}}, @settings)
              }>
                <button
                  type="button"
                  class="ui-button secondary"
                  phx-click="refresh-github-repositories"
                  disabled={@github_repository_discovery in [:idle, :loading]}
                >{if @github_repository_discovery in [:idle, :loading] and @github_repositories != [],
                  do: "Refreshing…",
                  else: "Refresh"}</button>
              </:action>
            </Components.page_header>
            <Ryker.ControlPlane.ChannelsPage.slack_status
              :if={@path == "/channels"}
              settings={@settings}
            />
            <%!-- The add page says where GitHub stands only while the form cannot
            show; once it works, its line would lead back to the page itself. --%>
            <Ryker.ControlPlane.RepositoriesPage.github_status
              :if={
                @path == "/repositories" or
                  (@path == "/repositories/new" and
                     not match?({:ok, %{github_connection: :ready}}, @settings))
              }
              settings={@settings}
            />
            <Components.form_feedback
              :if={repository_page?(@path) && match?({:list, _tone, _message}, @repository_notice)}
              id="repository-notice"
              class="page-feedback"
              tone={elem(@repository_notice, 1)}
              message={elem(@repository_notice, 2)}
            />
            {Phoenix.HTML.raw(@body)}
            <Kit.form_card
              :if={
                @path == "/repositories/new" &&
                  match?({:ok, %{github_connection: :ready}}, @settings)
              }
              label="Add repositories"
            >
              <Ryker.ControlPlane.RepositoryImport.repository_import
                view={elem(@settings, 1)}
                repositories={@github_repositories}
                discovery={@github_repository_discovery}
                notice={import_notice(@repository_notice)}
              />
            </Kit.form_card>
          </div>
          <Kit.confirm_modal
            :if={
              repository_page?(@path) and match?({"remove-repository", _ref}, @settings_confirm) and
                @repository_question
            }
            id="confirm-remove-repository"
            title={@repository_question.title}
            text={@repository_question.text}
            error={@repository_question.error}
            label="Remove repository"
            cancel="cancel-settings-action"
            phx-click="remove-repository"
            phx-value-repository={elem(@settings_confirm, 1)}
          />
          <Kit.confirm_modal
            :if={
              repository_page?(@path) and match?({"refresh-knowledge", _ref}, @settings_confirm) and
                @knowledge_question
            }
            id="confirm-refresh-knowledge"
            title={@knowledge_question.title}
            text={@knowledge_question.text}
            label="Refresh knowledge"
            tone={:primary}
            cancel="cancel-settings-action"
            phx-click="refresh-knowledge"
            phx-value-repository={elem(@settings_confirm, 1)}
          />
          <Kit.confirm_modal
            :if={@native == :instructions and match?({"leave-channel", _ref}, @settings_confirm)}
            id="confirm-leave-channel"
            title={"Remove Ryker from #{@page_title}?"}
            text="Ryker leaves the channel in Slack and stops reading and replying there. What it did and learned here stays, and its settings come back if you invite it again."
            label="Leave channel"
            cancel="cancel-settings-action"
            phx-click="leave-channel"
            phx-value-ref={elem(@settings_confirm, 1)}
          />
          <Kit.confirm_modal
            :if={@action_question}
            id="action-question"
            title={@action_question.title}
            text={@action_question.text}
            label={@action_question.label}
            tone={@action_question.tone}
            cancel="cancel-action"
            action={@action_question.action}
            token={@action_question.token}
          />
        </main>
      </div>
    </div>
    """
  end

  defp import_notice({:import, tone, message}), do: {tone, message}
  defp import_notice(_none_or_retry), do: nil

  # The switch that turns learning on or off belongs to the Learning list
  # alone. Andrew, 2026-09-27: "i don't need turn off button on subpages"; a
  # batch's page, which leads back to the list, only says what that batch did.
  defp learning_switch?("/memory/learning", params, {:ok, _view}),
    do: not Map.has_key?(params, "batch")

  defp learning_switch?(_path, _params, _settings), do: false
end
