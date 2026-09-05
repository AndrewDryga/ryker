defmodule Responder.ControlPlane.WorkbenchLive do
  @moduledoc "Live operator workspace. Browser state never owns execution custody."
  use Phoenix.LiveView, layout: false
  require Logger

  alias Responder.ControlPlane.{
    ActivityPage,
    CardLab,
    CardLabPage,
    Endpoint,
    EpisodePage,
    LabPage,
    Navigation,
    RequestPage,
    Router,
    Updates
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
       page_title: "Requests",
       connected: connected?(socket),
       unavailable: false,
       refresh_token: nil,
       refresh_failures: 0,
       paused: false,
       observed_at: nil,
       domain: nil,
       native: nil,
       overview: nil,
       activity: nil,
       schedules: [],
       row_ids: [],
       new_items: 0,
       episode: nil,
       requests: nil,
       request_selection: %{},
       lab: nil,
       card_lab: nil,
       lab_token: nil,
       lab_announcement: "",
       lab_items: [],
       lab_row_ids: []
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
       query: location.query || "",
       domain: domain,
       params: params,
       request_selection: %{},
       native: :loading,
       body: "",
       page_title: "Workspace",
       observed_at: nil
     )
     |> refresh(true)}
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

  def handle_info({:refresh_projection, token}, socket) do
    if token == socket.assigns.refresh_token do
      socket = assign(socket, :refresh_token, nil)
      {:noreply, if(socket.assigns.paused, do: socket, else: refresh(socket))}
    else
      {:noreply, socket}
    end
  end

  defp queue_refresh(%{assigns: %{paused: true}} = socket), do: socket

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
  def handle_event("toggle-live", _params, socket) do
    socket = assign(socket, :paused, not socket.assigns.paused)
    {:noreply, if(socket.assigns.paused, do: socket, else: refresh(socket))}
  end

  def handle_event(event, _params, socket) when event in ["refresh", "show-new"],
    do: {:noreply, refresh(socket, true)}

  def handle_event("search-activity", params, socket) do
    params =
      Map.merge(
        Map.take(socket.assigns.params, ~w(filter target repository state)),
        Map.take(params, ~w(q mode))
      )

    {:noreply,
     push_patch(socket, to: socket.assigns.path <> "?" <> URI.encode_query(params), replace: true)}
  end

  def handle_event(
        "card-transition",
        %{"id" => id},
        %{assigns: %{card_lab: %{snapshot: snapshot}}} = socket
      ) do
    case CardLab.transition(snapshot.card.id, snapshot.state.id, id) do
      {:ok, next} ->
        {:noreply, push_patch(socket, to: "/card-lab/#{next.card.id}/#{next.state.id}")}

      {:error, _} ->
        {:noreply, socket}
    end
  end

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
       when path in ["/", "/episodes"] do
    activity = options.projection.activity.(socket.assigns.params)
    schedules = options.projection.schedules.(%{"status" => "active"}) |> Enum.take(4)

    socket
    |> assign(
      native: :activity,
      page_title: "Requests",
      activity: Map.delete(activity, :items),
      overview: options.projection.overview.(),
      schedules: schedules
    )
    |> update_activity(activity.items, reset)
  end

  defp load_page(socket, options, _reset) do
    load_detail(socket, options, String.split(socket.assigns.path, "/", trim: true))
  end

  defp load_detail(socket, options, ["episodes", _ref | _rest]) do
    with {:ok, episode} <- options.projection.episode.(socket.assigns.params["ref"]),
         {:ok, requests} <- episode_requests(socket, options),
         {:ok, timeline} <- options.projection.model_timeline.(socket.assigns.params["ref"], %{}) do
      assign(socket,
        native: :episode,
        page_title: "Episode",
        episode: episode,
        timeline: timeline,
        requests: requests,
        request_selection: request_selection(requests)
      )
    else
      :not_found -> assign(socket, native: :not_found, page_title: "Not found")
    end
  end

  defp load_detail(socket, options, ["lab"]) do
    assign(socket,
      native: :lab,
      page_title: "Conversation Lab",
      lab: nil,
      lab_items: options.projection.lab_index.()
    )
  end

  defp load_detail(socket, options, ["card-lab"]),
    do: load_card(socket, options, CardLab.default())

  defp load_detail(socket, options, ["card-lab", card, state]) do
    case CardLab.fetch(card, state) do
      {:ok, snapshot} -> load_card(socket, options, snapshot)
      {:error, _} -> assign(socket, native: :not_found, page_title: "Not found")
    end
  end

  defp load_detail(socket, options, ["lab", _id]) do
    case Router.lab_snapshot(socket.assigns.params["id"], options) do
      {:ok, snapshot, token} ->
        reset =
          is_nil(socket.assigns.lab) or
            socket.assigns.lab.conversation_id != snapshot.conversation_id

        socket
        |> sync_lab_messages(snapshot.messages, reset)
        |> assign(
          native: :lab,
          page_title: "Conversation Lab",
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

  defp load_detail(socket, options, ["admission", _id]) do
    case options.projection.admission_request.(
           socket.assigns.params["id"],
           inspection_params(socket)
         ) do
      {:ok, requests} ->
        assign(socket,
          native: :request,
          page_title: "Admission",
          requests: requests,
          request_selection: request_selection(requests)
        )

      :not_found ->
        assign(socket, native: :not_found, page_title: "Not found")
    end
  end

  defp load_detail(socket, options, _segments) do
    page = Router.snapshot(socket.assigns.path, socket.assigns.query, options)
    if page.status >= 500, do: throw({:projection_unavailable, :secondary})
    assign(socket, native: nil, body: page.body, page_title: page.title)
  end

  defp episode_requests(socket, options) do
    if String.ends_with?(socket.assigns.path, "/requests"),
      do:
        options.projection.model_requests.(
          socket.assigns.params["ref"],
          inspection_params(socket)
        ),
      else: {:ok, nil}
  end

  defp load_card(socket, options, snapshot),
    do:
      assign(socket,
        native: :card_lab,
        page_title: "Slack Card Lab",
        card_lab: Router.card_lab_snapshot(snapshot, options)
      )

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

  defp lab_dom_id(message) do
    digest =
      :crypto.hash(:sha256, "#{message.actor}:#{message[:item_id] || message.ref}")
      |> Base.encode16(case: :lower)

    "lab-message-" <> digest
  end

  defp sync_lab_messages(socket, messages, true),
    do:
      socket
      |> stream(:lab_messages, messages, reset: true)
      |> assign(lab_row_ids: Enum.map(messages, &lab_dom_id/1))

  defp sync_lab_messages(socket, messages, false) do
    incoming = Enum.map(messages, &lab_dom_id/1)

    socket =
      Enum.reduce(
        socket.assigns.lab_row_ids -- incoming,
        socket,
        &stream_delete_by_dom_id(&2, :lab_messages, &1)
      )

    socket |> stream(:lab_messages, messages) |> assign(lab_row_ids: incoming)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="responder-app">
      <Navigation.sidebar path={@path} live={true} />
      <div class="app-workspace">
        <header class="app-topbar">
          <Navigation.mobile path={@path} live={true} />
          <div
            class="app-live"
            id="live-status"
            data-connection-state={if @connected, do: "connected", else: "connecting"}
          >
            <span class="view-freshness">Observed
            <time>{if @observed_at,
              do: Calendar.strftime(@observed_at, "%H:%M:%S UTC"),
              else: "not yet"}</time></span>
            <span class="connection-offline" role="status">Disconnected · reconnecting</span>
            <span class="connection-online" role="status">{cond do
              @unavailable -> "Data unavailable"
              @paused -> "Updates paused"
              @connected -> "Live updates"
              true -> "Connecting"
            end}</span>
            <button type="button" phx-click="toggle-live" aria-pressed={@paused}>{if @paused,
              do: "Resume",
              else: "Pause"}</button><button type="button" phx-click="refresh">Refresh</button>
          </div>
        </header>
        <div :if={@unavailable} class="app-warning" role="status">
          This view could not refresh. Showing the last observed state; execution continues independently.
          <button phx-click="refresh">Try again</button>
        </div>
        <main
          id="operator-page"
          class={if @native, do: "native-page", else: "legacy-surface"}
          phx-hook="PreserveReadingState"
        >
          <section :if={@native == :loading && @unavailable} class="document-unavailable">
            <h1>This view is temporarily unavailable</h1><p>
              Retry the view. No content from a different page is shown here.
            </p>
          </section>
          <ActivityPage.render
            :if={@native == :activity && @activity}
            activity={@activity}
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
            announcement={@lab_announcement}
          />
          <CardLabPage.render :if={@native == :card_lab} view={@card_lab} params={@params} />
          <div :if={@native == :request} class="standalone-inspector">
            <.link navigate="/" class="back-to-activity">← Activity</.link><RequestPage.render
              view={@requests}
              params={@params}
              path={@path}
            />
          </div>
          <section :if={@native == :not_found} class="document-unavailable">
            <h1>This record is unavailable</h1><p>
              It may not exist, or the selected request does not belong to this episode.
            </p><.link navigate="/" class="ui-button secondary">Back to activity</.link>
          </section>
          <div :if={!@native} class="secondary-page">
            <div class="secondary-page-title"><h1>{@page_title}</h1></div>{Phoenix.HTML.raw(@body)}
          </div>
        </main>
      </div>
    </div>
    """
  end
end
