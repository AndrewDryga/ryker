defmodule Responder.ControlPlane.WorkbenchLive do
  @moduledoc "Live operator workspace. Browser state never owns execution custody."
  use Phoenix.LiveView, layout: false
  require Logger

  alias Phoenix.HTML.Safe

  alias Responder.ControlPlane.{
    Activity,
    ActivityPage,
    ChannelDetail,
    ChannelPage,
    Components,
    Endpoint,
    EpisodePage,
    HTML,
    LabPage,
    Navigation,
    Projection,
    RequestFilters,
    RequestPage,
    Router,
    SettingsPage,
    SettingsView,
    SlackNames,
    Updates,
    UsageProjection
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Responder.ControlPlane.PubSub, "control-plane")
      Process.send_after(self(), :reconcile, 5_000)
    end

    {:ok,
     socket
     |> assign(
       path: "/",
       query: "",
       params: %{},
       body: "",
       page_title: "Activity",
       page_description: nil,
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
       overview: nil,
       activity: nil,
       filter_draft: %{},
       filter_draft_for_patch: nil,
       filter_values: [],
       schedules: [],
       row_ids: [],
       new_items: 0,
       episode: nil,
       disclosed: MapSet.new(),
       requests: nil,
       request_selection: %{},
       lab: nil,
       lab_token: nil,
       lab_announcement: "",
       lab_items: [],
       lab_window: nil
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

    patch_path = location.path <> if(location.query, do: "?" <> location.query, else: "")

    filter_draft =
      case socket.assigns.filter_draft_for_patch do
        {^patch_path, draft} -> draft
        _ -> RequestFilters.draft(params)
      end

    {:noreply,
     socket
     |> assign(
       path: location.path,
       query: location.query || "",
       domain: domain,
       params: params,
       filter_draft: filter_draft,
       filter_draft_for_patch: nil,
       request_selection: %{},
       disclosed: navigation_disclosures(socket, location.path),
       native: :loading,
       body: "",
       page_title: "Workspace",
       page_description: nil,
       observed_at: nil
     )
     |> refresh(true)}
  end

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
            Responder.ControlPlane.PubSub,
            "control-plane:#{socket.assigns.domain}"
          )

      Phoenix.PubSub.subscribe(Responder.ControlPlane.PubSub, "control-plane:#{domain}")
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

  def handle_event("initialize-settings", _params, socket) do
    case initialize_settings(socket) do
      {:ok, snapshot} ->
        {:noreply,
         assign(socket, settings: {:ok, SettingsView.view(snapshot)}, settings_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :settings_error, initialize_error(reason))}
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

    {:noreply,
     socket
     |> assign(:filter_draft_for_patch, {patch_path, socket.assigns.filter_draft})
     |> push_patch(to: patch_path, replace: true)}
  end

  def handle_event("edit-request-filters", params, socket),
    do:
      {:noreply,
       assign(socket, :filter_draft, RequestFilters.edit(socket.assigns.filter_draft, params))}

  def handle_event("apply-request-filters", params, socket) do
    query = RequestFilters.apply(socket.assigns.params, params) |> URI.encode_query()
    {:noreply, push_patch(socket, to: socket.assigns.path <> "?" <> query)}
  end

  # One older page of the open conversation. The request names the boundary
  # it expects to extend; anything else is a trigger that fired twice, a retry
  # of a page that already landed, or a request from a conversation this view
  # no longer shows, and each of those is answered, never loaded.
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

  defp refresh(socket, reset \\ false) do
    socket = assign(socket, :refresh_token, nil)
    options = Endpoint.config(:control_plane)
    socket = load_page(socket, options, reset)
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
         {:ok, requests} <- episode_requests(socket, options, episode.episode.ref),
         {:ok, timeline} <-
           options.projection.model_timeline.(socket.assigns.params["ref"], disclosed) do
      assign(socket,
        native: :episode,
        page_title: "Timeline",
        episode: episode,
        timeline: timeline,
        requests: requests,
        request_selection: request_selection(requests)
      )
    else
      :not_found -> load_unassigned_input(socket, options)
    end
  end

  defp load_detail(socket, options, ["configuration"]) do
    assign(socket,
      native: :settings,
      page_title: "Settings",
      settings: options.projection.settings.(),
      settings_commands: settings_commands(options),
      body: configuration_evidence(options)
    )
  end

  defp load_detail(socket, options, ["instructions"]) do
    {:ok, view} = options.projection.instructions.(:global)

    assign(socket,
      native: :instructions,
      page_title: "Instructions",
      body_lead: "",
      body: "",
      instructions: view,
      instruction_scope: :global,
      save_instructions: options.actions.save_instructions
    )
  end

  defp load_detail(socket, options, ["channels", workspace, channel]) do
    params = Map.take(socket.assigns.params, ChannelDetail.query_keys())

    with {:ok, snapshot} <- options.projection.channel.(workspace, channel, params),
         {:ok, view} <- options.projection.instructions.({:channel, workspace, channel}) do
      assign(socket,
        native: :instructions,
        page_title: SlackNames.name(workspace, channel),
        page_description: ChannelPage.description(snapshot),
        body_lead:
          ChannelPage.lead(%{__changed__: nil, view: snapshot})
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

  defp load_detail(socket, options, ["conversations"]) do
    assign(socket,
      native: :lab,
      page_title: "Conversations",
      lab: nil,
      lab_items: options.projection.lab_index.()
    )
  end

  defp load_detail(socket, options, ["conversations", _id]) do
    case Router.lab_snapshot(socket.assigns.params["id"], options) do
      {:ok, snapshot, token} ->
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
          lab_items: options.projection.lab_index.()
        )

      {:error, :path_ref} ->
        assign(socket, native: :not_found, page_title: "Not found")

      {:error, _} ->
        throw({:projection_unavailable, :lab})
    end
  end

  defp load_detail(socket, options, _segments), do: load_snapshot(socket, options)

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

  defp initialize_error(:settings_import_required),
    do:
      "This database already holds product history. Import the existing configuration instead: " <>
        "a new identity would re-key the worker, delivery and publication custody it belongs to."

  defp initialize_error(:settings_forbidden),
    do: "This console is not allowed to create settings."

  defp initialize_error(_reason),
    do: "Settings could not be created. Check that the database is reachable, then try again."

  # Read-only evidence of what the running process assembled. It is rendered
  # from the application environment the runtime published, not from settings,
  # so a saved-but-unapplied revision is visibly not in it.
  defp configuration_evidence(options) do
    options.projection.operator_configuration.()
    |> HTML.configuration()
    |> IO.iodata_to_binary()
  end

  defp load_snapshot(socket, options) do
    page = Router.snapshot(socket.assigns.path, socket.assigns.query, options)
    if page.status >= 500, do: throw({:projection_unavailable, :secondary})

    assign(socket,
      native: nil,
      body: page.body,
      page_title: page.title,
      page_description: page.description
    )
  end

  defp load_unassigned_input(
         %{assigns: %{params: %{"ref" => "ingress-input:" <> id}}} = socket,
         options
       ) do
    case options.projection.admission_request.(
           id,
           inspection_params(socket)
         ) do
      {:ok, %{episode_ref: nil} = requests} ->
        assign(socket,
          native: :request,
          page_title: "Request",
          requests: requests,
          request_selection: request_selection(requests)
        )

      _ ->
        assign(socket, native: :not_found, page_title: "Not found")
    end
  end

  defp load_unassigned_input(socket, _options),
    do: assign(socket, native: :not_found, page_title: "Not found")

  defp episode_requests(socket, options, episode_ref) do
    params = inspection_params(socket)

    selection =
      case socket.assigns.params["ref"] do
        "ingress-input:" <> id = input_ref
        when input_ref != episode_ref or is_map_key(params, "generation") ->
          Map.merge(params, %{"kind" => "admission", "attempt" => id})

        _ ->
          params
      end

    if String.ends_with?(socket.assigns.path, "/model-calls") or selection["kind"] == "admission",
      do: options.projection.model_requests.(episode_ref, selection),
      else: {:ok, nil}
  end

  defp inspection_params(socket),
    do: Map.merge(socket.assigns.params, socket.assigns.request_selection)

  defp request_selection(%{selected: %{id: id} = selected, kind: kind}) do
    params = %{"kind" => to_string(kind), "attempt" => id}

    if selected[:generation],
      do: Map.put(params, "generation", to_string(selected.generation)),
      else: params
  end

  defp request_selection(_), do: %{}

  defp update_activity(socket, items, true) do
    socket
    |> stream(:activity, items, reset: true)
    |> assign(row_ids: Enum.map(items, &dom_id/1), new_items: 0)
  end

  defp update_activity(socket, items, false) do
    current = socket.assigns.row_ids
    incoming = Enum.map(items, &dom_id/1)
    # Do not move existing rows beneath the reader. Removed rows must not remain actionable.
    socket = Enum.reduce(current -- incoming, socket, &stream_delete_by_dom_id(&2, :activity, &1))
    retained = Enum.filter(current, &(&1 in incoming))

    socket
    |> stream(:activity, Enum.filter(items, &(dom_id(&1) in current)))
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
          loaded: 0,
          page_size: history.page_size,
          rows: [],
          synced_at: DateTime.utc_now()
        },
        snapshot.messages
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
    since = DateTime.add(window.synced_at, -10, :second)
    synced_at = DateTime.utc_now()

    socket =
      case lab_bridge(snapshot.messages, history, window, options) do
        {:merge, messages} ->
          merge_lab_rows(socket, messages, nil)

        {:adopt, messages, history} ->
          socket
          |> stream(:lab_messages, [], reset: true)
          |> assign(:lab_window, %{
            window
            | before: history.before,
              digests: %{},
              exhausted: history.exhausted,
              failed: false,
              loaded: 0,
              rows: []
          })
          |> merge_lab_rows(messages, nil)
      end

    socket =
      case Router.lab_changes(window.conversation_id, since, window.page_size, options) do
        {:ok, changed} -> merge_lab_rows(socket, changed, lab_window_floor(socket))
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
      %{before: nil, exhausted: true, page_size: Projection.lab_page_size()}
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
        case Router.lab_history(
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
  defp merge_lab_rows(socket, messages, floor) do
    {socket, window} =
      Enum.reduce(messages, {socket, socket.assigns.lab_window}, fn message, {socket, window} ->
        merge_lab_row(socket, window, message, floor)
      end)

    assign(socket, :lab_window, %{window | loaded: length(window.rows)})
  end

  defp merge_lab_row(socket, window, message, floor) do
    dom_id = lab_dom_id(message)
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(message))

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

  defp lab_window_rows(window, messages) do
    rows = Enum.map(messages, &{lab_dom_id(&1), &1.sort_key})

    digests =
      Map.new(messages, &{lab_dom_id(&1), :crypto.hash(:sha256, :erlang.term_to_binary(&1))})

    %{window | digests: digests, loaded: length(rows), rows: rows}
  end

  defp load_older_page(socket) do
    window = socket.assigns.lab_window
    options = Endpoint.config(:control_plane)

    case Router.lab_history(window.conversation_id, window.before, window.page_size, options) do
      {:ok, page} ->
        socket =
          socket
          |> assign(:lab_window, %{
            window
            | before: page.before,
              exhausted: page.exhausted,
              failed: false
          })
          |> merge_lab_rows(page.messages, nil)

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
      class="responder-app"
      id="responder-shell"
      phx-hook="PreserveReadingState"
      data-connection-state={if @connected, do: "connected", else: "connecting"}
      data-updated-at={if @observed_at, do: DateTime.to_iso8601(@observed_at)}
    >
      <Navigation.sidebar path={@path} live={true} />
      <div class="app-workspace">
        <div class="mobile-navigation">
          <Navigation.mobile path={@path} live={true} />
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
          class={if @native, do: "native-page", else: "legacy-surface"}
        >
          <section :if={@native == :loading && @unavailable} class="document-unavailable">
            <h1>This view is temporarily unavailable</h1><p>
              Retry the view. No content from a different page is shown here.
            </p>
          </section>
          <ActivityPage.render
            :if={@native == :activity && @activity}
            activity={@activity}
            filter_draft={@filter_draft}
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
            requests={@requests}
            params={@params}
            timeline={@timeline}
          />
          <LabPage.render
            :if={@native == :lab}
            snapshot={@lab}
            token={@lab_token}
            items={@lab_items}
            messages={@streams.lab_messages}
            history={@lab_window}
            announcement={@lab_announcement}
          />
          <SettingsPage.render
            :if={@native == :settings}
            view={@settings}
            commands={@settings_commands}
            body={@body}
            error={@settings_error}
          />
          <div :if={@native == :instructions} class="secondary-page instructions-page">
            <Components.page_header title={@page_title} description={@page_description} />
            {Phoenix.HTML.raw(@body_lead)}
            <.live_component
              module={Responder.ControlPlane.InstructionsEditor}
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
              conversation_href={@requests.heading.conversation_href}
            />
            <EpisodePage.getting_ready
              :if={@requests[:preparation]}
              steps={@requests.preparation}
            />
            <RequestPage.render view={@requests} params={@params} path={@path} />
          </div>
          <section :if={@native == :not_found} class="document-unavailable">
            <h1>This record is unavailable</h1><p>
              It may not exist, or the selected request does not belong to this episode.
            </p><.link navigate="/" class="ui-button secondary">Back to activity</.link>
          </section>
          <div :if={!@native} class="secondary-page">
            <Components.page_header title={@page_title} description={@page_description} />{Phoenix.HTML.raw(
              @body
            )}
          </div>
        </main>
      </div>
    </div>
    """
  end
end
