defmodule Ryker.ControlPlane.WorkbenchLive do
  @moduledoc "Live operator workspace. Browser state never owns execution custody."
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
    ConversationProjection,
    Endpoint,
    Environments,
    EpisodePage,
    Integrations,
    LabControls,
    LabPage,
    Navigation,
    Pages,
    PathRef,
    RequestFilters,
    RunningSystem,
    SettingsPage,
    SettingsView,
    SlackNames,
    Updates,
    UsageProjection
  }

  alias Ryker.{IntegrationSetup, Settings}
  alias Ryker.Slack.ChannelConfigurations

  # Who a choice made on these pages is recorded as, like every other
  # control-plane write.
  @actor_ref "control-plane:local"
  @confirmed_settings_actions ~w(disconnect-slack disconnect-github delete-emisar delete-environment delete-webhook-credential)
  @settings_pages %{
    ["setup"] => :setup,
    ["environments"] => :environments,
    ["integrations"] => :integrations,
    ["integrations", "slack"] => :slack,
    ["integrations", "github"] => :github,
    ["integrations", "emisar"] => :emisar,
    ["integrations", "webhooks"] => :webhooks,
    ["settings", "models"] => :model,
    ["settings", "retention"] => :retention,
    ["settings", "prices"] => :pricing,
    ["settings", "advanced"] => :system
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Ryker.ControlPlane.PubSub, "control-plane")
      Process.send_after(self(), :reconcile, 5_000)
    end

    {:ok,
     socket
     |> assign(
       path: "/",
       params: %{},
       body: "",
       page_title: "Activity",
       page_description: nil,
       page_action: nil,
       connected: connected?(socket),
       unavailable: false,
       refresh_token: nil,
       refresh_failures: 0,
       observed_at: nil,
       domain: nil,
       native: nil,
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
       channel_notice: nil,
       slack_members: [],
       emisar_edit_ref: nil,
       webhook_credential_editing: false,
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
       lab_placeholder: nil,
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
    domain = Updates.domain(location.path)
    subscribe(socket, domain)

    {:noreply,
     socket
     |> assign(
       path: location.path,
       domain: domain,
       params: params,
       filter_menu: nil,
       disclosed: navigation_disclosures(socket, location.path),
       native: :loading,
       body: "",
       page_title: "Workspace",
       page_description: nil,
       observed_at: nil,
       webhook_credential_editing: false,
       # An outcome or an open question belongs to the page it happened on.
       # Closing an editor stays on its page, so what the save did stays said.
       setup_notice: if(location.path == socket.assigns.path, do: socket.assigns.setup_notice),
       setup_failure: nil,
       settings_confirm: nil,
       channel_notice: nil
     )
     |> assign_conversation_draft(location.path)
     |> refresh(true)}
  end

  # A conversation view is opened once per navigation: the index gets a fresh
  # identity nothing is written behind, and both get one composer placeholder
  # that later refreshes never re-roll. Refreshes come through refresh/2, not
  # here, so a five-second reconcile cannot hand the draft a new identity.
  defp assign_conversation_draft(socket, "/conversations") do
    assign(socket, lab_draft_id: Ecto.UUID.generate(), lab_placeholder: LabPage.random_example())
  end

  defp assign_conversation_draft(socket, "/conversations/" <> id) do
    assign(socket, lab_draft_id: nil, lab_placeholder: LabPage.example_for(id))
  end

  defp assign_conversation_draft(socket, _path),
    do: assign(socket, lab_draft_id: nil, lab_placeholder: nil)

  # Reading state belongs to one record. Navigating to a different Timeline must
  # not carry another record's opened bodies, which would load evidence the
  # reader never asked for on this page.
  defp navigation_disclosures(socket, path) do
    if socket.assigns.path == path, do: socket.assigns.disclosed, else: MapSet.new()
  end

  defp subscribe(socket, domain) do
    if connected?(socket) and domain != socket.assigns.domain do
      if socket.assigns.domain,
        do:
          Phoenix.PubSub.unsubscribe(
            Ryker.ControlPlane.PubSub,
            "control-plane:#{socket.assigns.domain}"
          )

      Phoenix.PubSub.subscribe(Ryker.ControlPlane.PubSub, "control-plane:#{domain}")
    end
  end

  @impl true
  def handle_info(:control_plane_changed, socket) do
    {:noreply, queue_refresh(socket)}
  end

  def handle_info(:reconcile, socket) do
    Process.send_after(self(), :reconcile, 5_000)
    {:noreply, queue_refresh(socket)}
  end

  def handle_info({:settings_saved, view}, socket) do
    {:noreply, assign(socket, settings: {:ok, view}, settings_error: nil)}
  end

  # A saved environment closes its editor and says so on the list.
  def handle_info({:environment_saved, view, message}, socket) do
    {:noreply,
     socket
     |> assign(settings: {:ok, view}, setup_notice: message, setup_failure: nil)
     |> push_patch(to: "/environments")}
  end

  def handle_info({:refresh_projection, token}, socket) do
    if token == socket.assigns.refresh_token do
      socket = assign(socket, :refresh_token, nil)
      {:noreply, refresh(socket)}
    else
      {:noreply, socket}
    end
  end

  defp queue_refresh(%{assigns: %{refresh_token: token}} = socket) when not is_nil(token),
    do: socket

  defp queue_refresh(socket) do
    token = make_ref()

    delay =
      if socket.assigns.refresh_failures == 0,
        do: 25,
        else: min(250 * Integer.pow(2, min(socket.assigns.refresh_failures, 6)), 15_000)

    Process.send_after(self(), {:refresh_projection, token}, delay)
    assign(socket, :refresh_token, token)
  end

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

  def handle_event("connect-slack", %{"connection" => params}, socket) do
    case IntegrationSetup.connect_slack(params) do
      {:ok, _result} ->
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

  def handle_event("discover-github-repositories", _params, socket) do
    case IntegrationSetup.github_repositories() do
      {:ok, repositories} ->
        {:noreply,
         assign(socket,
           github_repositories: repositories,
           github_repository_discovery: :complete,
           repository_notice: nil
         )}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           github_repository_discovery: {:error, setup_error(reason)},
           repository_notice: nil
         )}
    end
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
      # The list above gains the new rows at once, and the picker marks what
      # is now added, so a second "Add selected" cannot repeat the first.
      {:ok, result} ->
        handled = MapSet.new(result.added ++ result.already_present)

        {:noreply,
         socket
         |> assign(
           github_repositories:
             Enum.map(socket.assigns.github_repositories, fn repository ->
               if MapSet.member?(handled, repository.full_name),
                 do: %{repository | already_present: true},
                 else: repository
             end),
           repository_notice:
             {:import, import_tone(result), import_message(result, default_environment())}
         )
         |> refresh(true)}

      {:error, reason} ->
        {:noreply, assign(socket, repository_notice: {:import, :error, setup_error(reason)})}
    end
  end

  def handle_event("connect-emisar", %{"connection" => params}, socket) do
    result = IntegrationSetup.connect_emisar(params)
    {:noreply, finish_emisar_edit(socket, result, emisar_connected(result))}
  end

  def handle_event("show-emisar-form", %{"ref" => ref}, socket) when is_binary(ref) do
    {:noreply,
     assign(socket,
       emisar_edit_ref: ref,
       setup_notice: nil,
       setup_failure: nil,
       settings_confirm: nil
     )}
  end

  def handle_event("hide-emisar-form", _params, socket) do
    {:noreply, assign(socket, emisar_edit_ref: nil, settings_confirm: nil)}
  end

  def handle_event("rotate-emisar", %{"connection" => params}, socket) do
    result =
      IntegrationSetup.rotate_emisar(Map.get(params, "ref", ""), Map.get(params, "token", ""))

    {:noreply, finish_emisar_edit(socket, result, "Emisar token was rotated.")}
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
     finish_emisar_edit(
       socket,
       IntegrationSetup.disable_emisar_monitoring(ref),
       "Approval monitoring is off for this account."
     )}
  end

  def handle_event("enable-emisar-monitoring", %{"ref" => ref}, socket)
      when is_binary(ref) do
    {:noreply,
     finish_emisar_edit(
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

    {:noreply, finish_emisar_edit(socket, result, "Emisar account name was updated.")}
  end

  def handle_event("delete-emisar", %{"ref" => ref}, socket) when is_binary(ref) do
    confirmed(socket, {"delete-emisar", ref}, fn socket ->
      socket
      |> finish_setup(IntegrationSetup.delete_emisar(ref), "The Emisar account was removed.")
      |> assign(:emisar_edit_ref, nil)
    end)
  end

  # A channel's environment is its own setting, saved on its page the same
  # way the channel's setup in Slack saves it.
  def handle_event(
        "select-channel-environment",
        %{"workspace" => workspace, "channel" => channel, "environment" => environment},
        socket
      )
      when is_binary(workspace) and is_binary(channel) and is_binary(environment) do
    choice = if environment == "", do: nil, else: environment

    notice =
      case ChannelConfigurations.select_environment(workspace, channel, choice, @actor_ref) do
        {:ok, _configuration} -> {:success, channel_environment_saved(choice)}
        {:error, reason} -> {:error, channel_environment_error(reason)}
      end

    {:noreply, socket |> assign(:channel_notice, notice) |> refresh(true)}
  end

  # The default moves in one save: whichever environment had it gives it up.
  def handle_event("make-default-environment", %{"ref" => ref}, socket) when is_binary(ref) do
    {:noreply,
     write_environment(
       socket,
       ref,
       &Settings.put_environment(%{ref: ref, is_default: true}, &1, Settings.actor()),
       &"#{&1} is the default environment now."
     )}
  end

  def handle_event("delete-environment", %{"ref" => ref}, socket) when is_binary(ref) do
    confirmed(socket, {"delete-environment", ref}, fn socket ->
      write_environment(
        socket,
        ref,
        &Settings.delete_environment(ref, &1, Settings.actor()),
        &"#{&1} was removed."
      )
    end)
  end

  def handle_event("create-webhook-credential", %{"credential" => params}, socket) do
    case IntegrationSetup.create_webhook_credential(
           Map.get(params, "name", ""),
           Map.get(params, "secret")
         ) do
      {:ok, result} ->
        {:noreply,
         socket
         |> refresh_settings()
         |> assign(
           setup_notice: "Signing credential #{result.name} is ready.",
           setup_failure: nil,
           setup_reveal: %{label: "Signing secret", value: result.secret},
           webhook_credential_editing: false
         )}

      {:error, reason} ->
        {:noreply, failed(socket, reason)}
    end
  end

  def handle_event("show-webhook-credential-form", _params, socket),
    do: {:noreply, assign(socket, :webhook_credential_editing, true)}

  def handle_event("hide-webhook-credential-form", _params, socket),
    do: {:noreply, assign(socket, :webhook_credential_editing, false)}

  # Anything on the settings pages that disconnects or deletes asks first. The
  # button that starts it only opens the question; the action runs when the
  # question's own button sends it, so a double click never gets past it.
  def handle_event("confirm-settings-action", %{"action" => action, "ref" => ref}, socket)
      when action in @confirmed_settings_actions and is_binary(ref),
      do:
        {:noreply,
         assign(socket, settings_confirm: {action, ref}, setup_notice: nil, setup_failure: nil)}

  def handle_event("cancel-settings-action", _params, socket),
    do: {:noreply, assign(socket, :settings_confirm, nil)}

  def handle_event("disconnect-integration", %{"kind" => kind}, socket)
      when kind in ["slack", "github"] do
    confirmed(socket, {"disconnect-#{kind}", kind}, fn socket ->
      result = IntegrationSetup.disconnect(String.to_existing_atom(kind))

      finish_setup(
        socket,
        result,
        "#{if kind == "github", do: "GitHub", else: "Slack"} is disconnected."
      )
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
         |> assign(repository_notice: {:retry, :error, retry_error(reason)})
         |> refresh(true)}
    end
  end

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
          ~w(filter target repository state conversation thread transport) ++
            UsageProjection.filter_keys()
        ),
        Map.take(UsageProjection.link_params(params), ~w(q mode))
      )

    patch_path = socket.assigns.path <> "?" <> URI.encode_query(params)
    {:noreply, push_patch(socket, to: patch_path, replace: true)}
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

  defp refresh(socket, reset \\ false) do
    socket = assign(socket, :refresh_token, nil)
    options = Endpoint.config(:control_plane)
    socket = load_page(socket, options, reset)
    socket = assign(socket, :setup_progress, SettingsView.setup_progress())
    assign(socket, unavailable: false, refresh_failures: 0, observed_at: DateTime.utc_now())
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

    assign(socket,
      unavailable: true,
      refresh_token: nil,
      refresh_failures: min(socket.assigns.refresh_failures + 1, 6)
    )
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
    load_detail(socket, options, String.split(socket.assigns.path, "/", trim: true))
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

  # Setup, the integrations and the installation settings are one native page
  # family; the route map only lets through the pages that exist.
  defp load_detail(socket, options, segments) when is_map_key(@settings_pages, segments) do
    section = Map.fetch!(@settings_pages, segments)

    assign(socket,
      native: :settings,
      page_title: SettingsPage.title(section),
      settings: options.projection.settings.(),
      settings_commands: settings_commands(options),
      settings_section: section,
      body: if(section == :system, do: configuration_evidence(options), else: "")
    )
  end

  # The global editor, then the channels that add their own instructions and
  # the preferences and guidance people saved from conversations.
  defp load_detail(socket, options, ["instructions"]) do
    {:ok, view} = options.projection.instructions.(:global)

    saved =
      options.projection.behaviors.(
        [:preference, :guidance],
        Map.take(socket.assigns.params, ["show", "status", "page"])
      )

    assign(socket,
      native: :instructions,
      page_title: "Instructions",
      page_description: ConfigurationGuide.description(:instructions),
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
        page_title: SlackNames.name(workspace, channel),
        page_description: ChannelPage.description(snapshot),
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
        assign(socket, native: :not_found, page_title: "Not found")

      {:error, _} ->
        throw({:projection_unavailable, :lab})
    end
  end

  defp load_detail(socket, options, _segments), do: load_snapshot(socket, options)

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
      readiness: options.projection.readiness.()
    )
  end

  defp settings_commands(options) do
    Map.take(options.actions, [
      :delete_settings_item,
      :initialize_settings,
      :preview_retention,
      :preview_webhook,
      :put_settings_item,
      :save_settings
    ])
    |> Map.new(fn {key, callback} -> {command_name(key), callback} end)
  end

  defp command_name(:delete_settings_item), do: :delete_item
  defp command_name(:initialize_settings), do: :initialize
  defp command_name(:preview_retention), do: :preview_retention
  defp command_name(:preview_webhook), do: :preview_webhook
  defp command_name(:put_settings_item), do: :put_item
  defp command_name(:save_settings), do: :save

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
    do: assign(socket, setup_notice: nil, setup_failure: setup_error(reason), setup_reveal: nil)

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

  defp finish_emisar_edit(socket, {:ok, _result} = result, message) do
    socket
    |> finish_setup(result, message)
    |> assign(:emisar_edit_ref, nil)
  end

  defp finish_emisar_edit(socket, {:error, _reason} = result, message),
    do: finish_setup(socket, result, message)

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

  defp emisar_connected({:error, _reason}), do: nil

  # One write to one environment at the revision the page shows. A removal the
  # settings refuse names who still chooses the environment.
  defp write_environment(socket, ref, write, done) do
    with {:ok, view} <- socket.assigns.settings,
         %{} = environment <- Environments.find(view.snapshot, ref) do
      case write.(view.revision) do
        {:ok, _snapshot} ->
          socket
          |> refresh_settings()
          |> assign(setup_notice: done.(environment.display_name), setup_failure: nil)

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

  defp setup_error({:slack_missing_scopes, scopes}),
    do: "Slack is missing: " <> Enum.join(scopes, ", ")

  defp setup_error({:invalid_github_app_jwt, :private_key}),
    do: "GitHub could not read the App private key. Replace the connection, then try again."

  defp setup_error(:credential_name_invalid),
    do: "That name cannot be used. Use lowercase letters, numbers, dots, dashes and colons."

  defp setup_error(:credential_value_invalid), do: "That secret is empty or too long."
  defp setup_error(:connection_not_found), do: "That account no longer exists. Reload the page."

  defp setup_error(:environment_not_found),
    do: "That environment no longer exists. Reload the page."

  defp setup_error(:emisar_account_mismatch),
    do: "That token belongs to a different Emisar account."

  defp setup_error({:invalid_settings, _errors}),
    do: "These values were refused. Check them and try again."

  defp setup_error({:settings_conflict, _current}),
    do: "The settings changed in the meantime. Reload the page and try again."

  defp setup_error({provider, reason})
       when is_atom(provider) and (is_atom(reason) or is_binary(reason)),
       do: "Connection could not be verified (#{reason})."

  defp setup_error(_reason),
    do: "Connection could not be verified. Check the values and try again."

  defp channel_environment_saved(nil),
    do: "Saved. Ryker now works here without code or an Emisar account."

  defp channel_environment_saved(ref) do
    name =
      with {:ok, view} <- SettingsView.fetch(),
           %{display_name: name} <- Environments.find(view.snapshot, ref) do
        name
      else
        _unknown -> ref
      end

    "Saved. This channel works in #{name} now."
  end

  defp channel_environment_error(:configuration_not_found),
    do: "Ryker has no settings for this channel yet. Invite Ryker to the channel first."

  defp channel_environment_error(:environment_not_found),
    do: "That environment no longer exists. Reload the page and choose again."

  defp channel_environment_error(_reason),
    do: "The environment could not be saved. Reload the page and try again."

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

  # Read-only evidence of what the running process assembled. It is rendered
  # from the application environment the runtime published, not from settings,
  # so a saved-but-unapplied revision is visibly not in it.
  defp configuration_evidence(options) do
    options.projection.operator_configuration.()
    |> RunningSystem.html()
  end

  # A secondary page is prepared whole by Pages from the path as the browser
  # sent it; a 503 keeps the last observed page on screen rather than
  # replacing it with an error page that would read as the record's state.
  defp load_snapshot(socket, options) do
    segments = String.split(socket.assigns.path, "/", trim: true)
    page = Pages.page(segments, socket.assigns.params, options)
    if page.status >= 500, do: throw({:projection_unavailable, :secondary})

    assign(socket,
      native: nil,
      body: page.body,
      page_title: page.title,
      page_description: page.description,
      page_action: Map.get(page, :action),
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
          page_title: "Request",
          requests: requests
        )

      _ ->
        assign(socket, native: :not_found, page_title: "Not found")
    end
  end

  defp load_unassigned_input(socket, _options),
    do: assign(socket, native: :not_found, page_title: "Not found")

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
            placeholder={@lab_placeholder}
            readiness={@readiness}
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
            emisar_edit_ref={@emisar_edit_ref}
            webhook_credential_editing={@webhook_credential_editing}
            params={@params}
          />
          <div :if={@native == :instructions} class="secondary-page instructions-page">
            <Components.page_header title={@page_title} description={@page_description} />
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
          <div :if={@native == :request} class="episode-workbench execution-document">
            <EpisodePage.unrouted_intro
              :if={@requests[:heading]}
              title={@requests.heading.title}
              received_at={@requests.heading.received_at}
              conversation_link={@requests.heading.conversation_link}
            />
            <EpisodePage.admission_recovery
              :if={@requests.selected[:recovery]}
              recovery={@requests.selected.recovery}
            />
            <EpisodePage.getting_ready
              :if={@requests[:preparation]}
              steps={@requests.preparation}
              requests={@requests.timeline}
            />
          </div>
          <section :if={@native == :not_found} class="document-unavailable">
            <h1>This record is unavailable</h1><p>
              It may not exist, or the selected request does not belong to this episode.
            </p><.link navigate="/" class="ui-button secondary">Back to activity</.link>
          </section>
          <div :if={!@native} class="secondary-page">
            <Components.page_header title={@page_title} description={@page_description}>
              <:action :if={@page_action}>{Phoenix.HTML.raw(@page_action)}</:action>
              <:action :if={@path == "/memory/learning" && match?({:ok, _view}, @settings)}>
                <.live_component
                  module={Ryker.ControlPlane.LearningSwitch}
                  id="learning-switch"
                  view={elem(@settings, 1)}
                  commands={@settings_commands}
                />
              </:action>
            </Components.page_header>
            <Ryker.ControlPlane.ChannelsPage.slack_status
              :if={@path == "/channels"}
              settings={@settings}
            />
            <Ryker.ControlPlane.RepositoriesPage.github_status
              :if={@path == "/repositories"}
              settings={@settings}
            />
            <Components.form_feedback
              :if={@path == "/repositories" && match?({:retry, _tone, _message}, @repository_notice)}
              id="repository-retry-notice"
              tone={elem(@repository_notice, 1)}
              message={elem(@repository_notice, 2)}
            />
            {Phoenix.HTML.raw(@body)}
            <Ryker.ControlPlane.RepositoryImport.repository_import
              :if={
                @path == "/repositories" &&
                  match?({:ok, %{github_connection: :ready}}, @settings)
              }
              view={elem(@settings, 1)}
              repositories={@github_repositories}
              discovery={@github_repository_discovery}
              notice={import_notice(@repository_notice)}
            />
          </div>
        </main>
      </div>
    </div>
    """
  end

  defp import_notice({:import, tone, message}), do: {tone, message}
  defp import_notice(_none_or_retry), do: nil
end
