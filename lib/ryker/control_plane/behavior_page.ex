defmodule Ryker.ControlPlane.BehaviorPage do
  @moduledoc """
  Rules (/rules), and the preferences and guidance people saved from
  conversations (the lower half of /instructions), as Kit rows with the
  existing confirmed Pause, Resume and Delete actions.

  Every entry here is created only by asking Ryker and confirming what it
  proposes, so the pages say how to ask instead of offering a create button.
  A row names the entry, says what it does, then one line of facts; nothing
  in a list is a raw enum, reference or JSON.
  """
  use Phoenix.Component
  alias Ryker.ControlPlane.{Components, Kit, SlackNames}

  attr(:view, :map, required: true, doc: "BehaviorLibrary.list(:standing_assignment, params)")
  attr(:now, :any, default: nil)

  @doc "The /rules body: search and Current/Past, the rules, how to add one, then recent matches."
  def rules(assigns) do
    assigns =
      assign(assigns,
        now: assigns[:now] || DateTime.utc_now(),
        q: assigns.view.params["q"] || "",
        past: assigns.view.params["status"] == "past"
      )

    ~H"""
    <div class="behavior-page">
      <Kit.toolbar>
        <Components.filter_toolbar
          id="behavior-search"
          path="/rules"
          label="Search rules"
          placeholder="Search rules"
          query={@q}
          filtered={@q != ""}
          hidden={if @past, do: [{"status", "past"}], else: []}
          clear={rules_url(@view, q: "")}
        />
        <Kit.segmented
          label="Show current or past rules"
          options={[
            {"Current", rules_url(@view, status: "current"), !@past},
            {"Past", rules_url(@view, status: "past"), @past}
          ]}
        />
      </Kit.toolbar>
      <Kit.entity_list :if={@view.items != []} label="Rules">
        <.entry :for={item <- @view.items} item={item} now={@now} />
      </Kit.entity_list>
      <Kit.empty :if={@view.items == []} title={rules_empty(@view)} text={rules_empty_text(@view)}>
        <a :if={@q != ""} href={rules_url(@view, q: "")}>Clear the search</a>
      </Kit.empty>
      <Components.pager
        page={@view.page}
        pages={@view.pages}
        path={&rules_url(@view, page: &1)}
        label="Rule pages"
        summary={count(@view.total, "rule", "rules")}
      />
      <Kit.ask_hint
        lead="To add a rule, tell Ryker in the channel:"
        example="When someone posts a Terraform plan here, review it for risky changes."
        rest="Ryker shows the rule and saves it only after you confirm."
      />
      <section :if={@view.items != []} class="behavior-matches" aria-labelledby="rule-matches">
        <Kit.section_head
          id="rule-matches"
          title="Recent matches"
          lede="The latest messages that set off a rule on this page, newest first."
        />
        <Kit.entity_list :if={@view.runs != []} label="Recent matches">
          <Kit.entity_row
            :for={run <- @view.runs}
            name={rule_name(@view.items, run.rule_ref)}
            href={"#behavior-" <> run.rule_ref}
            meta={[outcome(run), when_fact(run.at, @now)]}
          >
            <:actions :if={run.episode_ref}>
              <a
                class="ui-button secondary"
                href={"/timeline/" <> URI.encode_www_form(run.episode_ref)}
              >Open<span class="sr-only"> what Ryker did</span></a>
            </:actions>
          </Kit.entity_row>
        </Kit.entity_list>
        <Kit.empty
          :if={@view.runs == []}
          title="No matches yet"
          text="When a message sets off one of these rules, it shows up here."
        />
      </section>
    </div>
    """
  end

  attr(:channels, :list, required: true, doc: "Channels with instructions of their own")

  attr(:saved, :map,
    required: true,
    doc: "BehaviorLibrary.list([:preference, :guidance], params)"
  )

  attr(:now, :any, default: nil)

  @doc """
  The /instructions sections under the global editor: the channels that add
  instructions of their own, then the preferences and guidance people
  confirmed in conversations.
  """
  def instructions(assigns) do
    assigns =
      assign(assigns,
        now: assigns[:now] || DateTime.utc_now(),
        channel_rows: channel_rows(assigns.channels)
      )

    ~H"""
    <div class="behavior-page">
      <section class="instructions-channels" aria-labelledby="channels">
        <Kit.section_head
          id="channels"
          title="For specific channels"
          lede="Added to the instructions above, in that channel only."
        />
        <Kit.entity_list :if={@channel_rows != []} label="Channel instructions">
          <Kit.entity_row
            :for={row <- @channel_rows}
            id={row.id}
            name={row.name}
            href={row.page}
            text={row.quote}
          >
            <:actions>
              <a class="ui-button secondary" href={row.href}>Edit<span class="sr-only"> the instructions for {row.name}</span></a>
            </:actions>
          </Kit.entity_row>
        </Kit.entity_list>
        <Kit.empty
          :if={@channel_rows == []}
          title="No channel has its own instructions yet"
          text="When something should apply in one channel only, open that channel and add instructions there."
        />
        <a class="ui-button secondary behavior-add" href="/channels"><Components.icon name={:plus} />Add for a channel</a>
      </section>
      <section class="instructions-saved" aria-labelledby="saved">
        <Kit.section_head
          id="saved"
          title="Saved from conversations"
          lede="Preferences and guidance people confirmed in chat or Slack."
        />
        <Kit.toolbar>
          <Kit.segmented
            label="Show preferences, guidance or both"
            options={[
              {"All", saved_url(@saved, show: "all"), @saved.params["show"] == "all"},
              {"Preferences", saved_url(@saved, show: "preferences"),
               @saved.params["show"] == "preferences"},
              {"Guidance", saved_url(@saved, show: "guidance"), @saved.params["show"] == "guidance"}
            ]}
          />
          <Kit.segmented
            label="Show current or past entries"
            options={[
              {"Current", saved_url(@saved, status: "current"), @saved.params["status"] != "past"},
              {"Past", saved_url(@saved, status: "past"), @saved.params["status"] == "past"}
            ]}
          />
        </Kit.toolbar>
        <Kit.entity_list :if={@saved.items != []} label="Saved from conversations">
          <.entry :for={item <- @saved.items} item={item} now={@now} />
        </Kit.entity_list>
        <Kit.empty
          :if={@saved.items == []}
          title={saved_empty(@saved)}
          text={saved_empty_text(@saved)}
        />
        <Components.pager
          page={@saved.page}
          pages={@saved.pages}
          path={&saved_url(@saved, page: &1)}
          label="Saved entry pages"
          summary={count(@saved.total, "entry", "entries")}
        />
        <Kit.ask_hint
          lead="To add one, tell Ryker:"
          example="Remember to keep incident updates short."
          rest="Ryker shows what it will save and keeps it only after you confirm."
        />
      </section>
    </div>
    """
  end

  attr(:item, :map, required: true)
  attr(:now, :any, required: true)

  # One rule, preference or guidance entry. Pause or Resume stays visible;
  # Delete and the link to where it was agreed sit in the "⋯" menu. Every
  # control is a GET to the existing confirmation page, so opening the menu
  # or a disclosure changes nothing.
  defp entry(assigns) do
    item = assigns.item
    text = text(item)
    long = is_binary(text) and long?(text)

    assigns =
      assign(assigns,
        id: "behavior-" <> item.ref,
        name: subject(item),
        text: if(long, do: preview(text), else: text),
        full: if(long, do: text),
        conditions: conditions(item),
        manageable: item.status in ["active", "disabled"],
        source: source_url(item)
      )

    ~H"""
    <Kit.entity_row
      id={@id}
      name={@name}
      icon={:bolt}
      state={state(@item.status)}
      text={@text}
      meta={facts(@item, @now)}
    >
      <:details :if={@full || @conditions != []}>
        <details :if={@full} class="behavior-more behavior-full" id={@id <> "-full"}>
          <summary phx-no-format><span class="behavior-closed">Show all</span><span class="behavior-open">Show less</span></summary>
          <p class="behavior-full-text">{@full}</p>
        </details>
        <details
          :if={@conditions != []}
          class="behavior-more behavior-conditions"
          id={@id <> "-conditions"}
        >
          <summary>Conditions</summary>
          <ul>
            <li :for={condition <- @conditions}>{condition}</li>
          </ul>
        </details>
      </:details>
      <:actions :if={@manageable || @source}>
        <Components.action_button
          :if={@manageable}
          path={action(@item, if(@item.status == "active", do: "disabled", else: "active"))}
          label={if @item.status == "active", do: "Pause", else: "Resume"}
        />
        <details class="behavior-menu" id={@id <> "-menu"}>
          <summary phx-no-format><span class="behavior-menu-glyph" aria-hidden="true">⋯</span><span class="sr-only">More actions for {@name}</span></summary>
          <div class="behavior-menu-items">
            <a :if={@source} href={@source} rel="noopener noreferrer">Open original conversation</a>
            <Components.action_button
              :if={@manageable}
              path={action(@item, "deleted")}
              label="Delete"
              tone={:danger}
            />
          </div>
        </details>
      </:actions>
    </Kit.entity_row>
    """
  end

  @doc """
  The name a person knows an entry by: a rule's title (or what a typed rule
  does), a preference as "Reply length: Concise", and guidance by its
  subject. Confirmation pages ask "Pause <name>?" with it.
  """
  def subject(%{kind: :standing_assignment, payload: payload}),
    do: payload["title"] || rule_name(payload)

  def subject(%{kind: :preference, payload: payload}),
    do: preference_key(payload["key"]) <> ": " <> preference_value(payload["value"])

  def subject(%{kind: :guidance, payload: payload}),
    do: payload["subject"] || payload["summary"] || "Guidance"

  def subject(%{payload: payload}),
    do: payload["title"] || payload["subject"] || payload["task"] || "Saved instruction"

  defp rule_name(%{"action" => "review_terraform_plan"}), do: "Review Terraform plans"
  defp rule_name(%{"action" => "verify_deployment"}), do: "Check deployments"
  defp rule_name(%{"action" => "triage_alert"}), do: "Triage alerts"
  defp rule_name(%{"trigger" => "terraform_plan"}), do: "Terraform plans"
  defp rule_name(%{"trigger" => "deployment"}), do: "Deployments"
  defp rule_name(%{"trigger" => "operational_alert"}), do: "Alerts"
  defp rule_name(%{"trigger" => trigger}) when is_binary(trigger), do: Components.label(trigger)
  defp rule_name(_payload), do: "Rule"

  defp preference_key("response_detail"), do: "Reply length"
  defp preference_key("health_check_depth"), do: "Health checks"
  defp preference_key("response_location"), do: "Where to reply"
  defp preference_key(key) when is_binary(key), do: Components.label(key)
  defp preference_key(_key), do: "Preference"

  defp preference_value("follow_context"), do: "Where the conversation is"
  defp preference_value("prefer_thread"), do: "In the thread"
  defp preference_value("prefer_channel"), do: "In the channel"
  defp preference_value(value) when is_binary(value), do: Components.label(value)
  defp preference_value(_value), do: "Not recorded"

  # What the entry tells Ryker to do, in its own stored words. A preference
  # is its name alone.
  defp text(%{kind: :standing_assignment, payload: payload}), do: payload["task"]
  defp text(%{kind: :guidance, payload: payload}), do: payload["text"] || payload["summary"]
  defp text(_item), do: nil

  defp state("active"), do: {:on, "On"}
  defp state("disabled"), do: {:off, "Paused"}
  defp state("expired"), do: {:off, "Expired"}
  defp state("deleted"), do: {:off, "Deleted"}
  defp state("superseded"), do: {:off, "Replaced"}
  defp state(status), do: {:off, Components.label(status)}

  # A long entry opens from a preview of its own first lines. Nothing is
  # summarised: the disclosure holds the stored text verbatim, and a short
  # entry gets no empty control.
  @preview_limit 200
  @preview_lines 2

  defp long?(text),
    do: String.length(text) > @preview_limit or length(String.split(text, "\n")) > @preview_lines

  defp preview(text) do
    head = text |> String.split("\n") |> Enum.take(@preview_lines) |> Enum.join("\n")

    cut =
      if String.length(head) > @preview_limit,
        do: head |> String.slice(0, @preview_limit) |> String.replace(~r/\s+\S*\z/u, ""),
        else: head

    String.trim_trailing(cut) <> "…"
  end

  # The one line of facts. A rule says when it acts, who can set it off, the
  # repository it works in, when it stops and how often it ran; a saved entry
  # says what it is, where it applies, how often it was used and when it stops.
  defp facts(%{kind: :standing_assignment} = item, now) do
    [
      trigger(item),
      sender(item.payload["source_filter"]),
      if(item.payload["repository"], do: rich(["uses ", {:strong, item.payload["repository"]}])),
      expiry(item, now),
      usage(item, now)
    ]
  end

  defp facts(item, now) do
    [kind_word(item.kind), where(item), usage(item, now), expiry(item, now)]
  end

  defp kind_word(:preference), do: "Preference"
  defp kind_word(:guidance), do: "Guidance"
  defp kind_word(kind), do: Components.label(kind)

  defp trigger(%{payload: %{"source_kind" => source} = payload} = item) do
    matching = if payload["filter"] in [nil, %{}], do: "a ", else: "a matching "
    rich(["When " <> matching <> source_event(source) <> " arrives" | place(item)])
  end

  defp trigger(%{payload: payload} = item),
    do: rich([trigger_event(payload["trigger"]) | place(item)])

  defp trigger_event("terraform_plan"), do: "When someone posts a Terraform plan"
  defp trigger_event("deployment"), do: "When someone posts about a deployment"
  defp trigger_event("operational_alert"), do: "When an alert arrives"
  defp trigger_event(_trigger), do: "When a matching message arrives"

  defp source_event("github"), do: "GitHub event"
  defp source_event("slack"), do: "Slack event"
  defp source_event("webhook"), do: "webhook"
  defp source_event(source) when is_binary(source), do: Components.label(source) <> " event"

  defp place(%{scope_kind: :conversation, scope_ref: "slack:" <> _ = scope}),
    do: [" in ", {:strong, SlackNames.destination(scope)}]

  defp place(%{scope_kind: :conversation}), do: [" in a direct conversation"]

  defp place(%{scope_kind: :repository, scope_ref: repository}),
    do: [" in ", {:strong, repository}]

  defp place(%{scope_kind: :workspace}), do: [" anywhere in the workspace"]
  defp place(_item), do: []

  defp sender("human"), do: "people only"
  defp sender("app"), do: "apps only"
  defp sender("any"), do: "people and apps"
  defp sender(_filter), do: nil

  # Where a preference or guidance entry applies.
  defp where(%{scope_kind: :workspace}), do: "everywhere"

  defp where(%{scope_kind: :conversation, scope_ref: "slack:" <> _ = scope}),
    do: rich(["in ", {:strong, SlackNames.destination(scope)}])

  defp where(%{scope_kind: :conversation}), do: "in a direct conversation"

  defp where(%{scope_kind: :repository, scope_ref: repository}),
    do: rich(["for ", {:strong, repository}])

  defp where(%{
         scope_kind: :operator,
         scope_ref: "slack:user:" <> person,
         workspace_ref: "slack:" <> workspace
       }) do
    if SlackNames.named?("slack:#{workspace}:#{person}"),
      do: rich(["for ", {:strong, SlackNames.name(workspace, person)}]),
      else: "for one person"
  end

  defp where(%{scope_kind: :operator}), do: "for one person"
  defp where(_item), do: nil

  defp expiry(%{status: "expired", expires_at: %DateTime{} = at}, now),
    do: rich([{:time, at, "stopped " <> day(at, now)}])

  defp expiry(%{status: status, expires_at: %DateTime{} = at}, now)
       when status in ["active", "disabled"],
       do: rich([{:time, at, "stops " <> day(at, now)}])

  defp expiry(_item, _now), do: nil

  defp usage(%{use_count: count} = item, now) when is_integer(count) and count > 0 do
    times = if count == 1, do: "used once", else: "used #{count} times"

    case item.last_used_at do
      %DateTime{} = at ->
        rich([times <> if(count == 1, do: ", ", else: ", last "), {:time, at, ago(at, now)}])

      _never_recorded ->
        times
    end
  end

  defp usage(_item, _now), do: "not used yet"

  # A source-event rule matches the event's fields exactly; its conditions
  # are the one technical detail a person may need, so they sit in a closed
  # disclosure as field-is-value lines.
  defp conditions(%{kind: :standing_assignment, payload: %{"filter" => filter}})
       when is_map(filter) and map_size(filter) > 0,
       do: filter |> flatten([]) |> Enum.map(&condition/1)

  defp conditions(%{kind: :standing_assignment, payload: %{"filter" => filter}})
       when is_binary(filter),
       do: [filter]

  defp conditions(_item), do: []

  defp flatten(value, path) when is_map(value) and map_size(value) > 0,
    do:
      value
      |> Enum.sort()
      |> Enum.flat_map(fn {key, nested} -> flatten(nested, path ++ [key]) end)

  defp flatten(value, path), do: [{Enum.join(path, "."), value}]

  defp condition({field, value}) do
    rich([
      {:code, field},
      " is ",
      {:code, if(is_binary(value), do: value, else: Jason.encode!(value))}
    ])
  end

  defp action(item, status), do: "/actions/behavior/#{URI.encode_www_form(item.ref)}/#{status}"

  defp rule_name(items, ref) do
    case Enum.find(items, &(&1.ref == ref)) do
      nil -> "Rule"
      item -> subject(item)
    end
  end

  defp outcome(%{outcome: :pending}), do: "Waiting for Ryker"
  defp outcome(%{outcome: :superseded}), do: "Replaced by a newer message"
  defp outcome(%{action: :ignore}), do: "No reply needed"
  defp outcome(%{action: :start_episode}), do: "Started work"
  defp outcome(%{action: :continue_episode}), do: "Continued earlier work"
  defp outcome(%{action: :reply}), do: "Replied"
  defp outcome(%{action: :react}), do: "Reacted"
  defp outcome(_run), do: "Handled"

  defp when_fact(%DateTime{} = at, now), do: rich([{:time, at, ago(at, now)}])
  defp when_fact(_at, _now), do: nil

  defp rules_empty(%{params: %{"q" => q}}) when q != "", do: "No rules match “#{q}”"

  defp rules_empty(%{params: params, counts: counts}) do
    cond do
      counts == %{} -> "No rules yet"
      params["status"] == "past" -> "No past rules"
      true -> "No rules are on or paused"
    end
  end

  defp rules_empty_text(%{params: %{"q" => q}}) when q != "", do: nil

  defp rules_empty_text(%{params: params, counts: counts}) do
    cond do
      counts == %{} ->
        "A rule shows up here once someone asks Ryker for one and confirms it."

      params["status"] == "past" ->
        "Rules show up here after they expire, are deleted or are replaced."

      true ->
        "Rules that expired, were deleted or were replaced are under Past."
    end
  end

  defp saved_empty(%{params: params, counts: counts}) do
    noun =
      case params["show"] do
        "preferences" -> "preferences"
        "guidance" -> "guidance"
        _all -> "preferences or guidance"
      end

    cond do
      counts == %{} and params["show"] == "all" -> "Nothing saved yet"
      counts == %{} -> "No #{noun} yet"
      params["status"] == "past" -> "No past #{noun}"
      true -> "No current #{noun}"
    end
  end

  defp saved_empty_text(%{params: params, counts: counts}) do
    cond do
      counts == %{} ->
        "Entries show up here once someone asks Ryker to remember one and confirms it."

      params["status"] == "past" ->
        "Entries show up here after they expire, are deleted or are replaced."

      true ->
        "Entries that expired, were deleted or were replaced are under Past."
    end
  end

  defp rules_url(view, changes),
    do: url("/rules", Map.take(view.params, ["q", "status"]), changes, "")

  defp saved_url(view, changes),
    do: url("/instructions", Map.take(view.params, ["show", "status"]), changes, "#saved")

  # A shareable address holding only what differs from the page's defaults.
  # Changing a filter starts again at page one.
  defp url(path, params, changes, fragment) do
    query =
      params
      |> Map.merge(Map.new(changes, fn {key, value} -> {Atom.to_string(key), value} end))
      |> Enum.reject(fn {key, value} ->
        value in [nil, "", 1] or {key, value} in [{"status", "current"}, {"show", "all"}]
      end)
      |> Enum.sort()
      |> URI.encode_query()

    if query == "", do: path <> fragment, else: path <> "?" <> query <> fragment
  end

  defp count(1, one, _many), do: "1 " <> one
  defp count(total, _one, many), do: "#{total} " <> many

  defp channel_rows(channels) do
    channels
    |> Enum.map(fn channel ->
      name = SlackNames.name(channel.workspace_ref, channel.channel_ref)
      page = "/channels/#{segment(channel.workspace_ref)}/#{segment(channel.channel_ref)}"

      %{
        id: "channel-instructions-#{channel.workspace_ref}-#{channel.channel_ref}",
        name: name,
        page: page,
        quote: "“" <> clamp(channel.text) <> "”",
        href: page <> "#instructions-slack:#{channel.workspace_ref}:#{channel.channel_ref}"
      }
    end)
    |> Enum.sort_by(&String.downcase(&1.name))
  end

  # One or two lines of a channel's instructions; the whole text is one
  # click away on the channel's page.
  @quote_limit 160
  defp clamp(text) do
    text = text |> String.split() |> Enum.join(" ")

    if String.length(text) > @quote_limit,
      do: (text |> String.slice(0, @quote_limit) |> String.replace(~r/\s+\S*\z/u, "")) <> "…",
      else: text
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  # A fact with emphasised references, code or a time in it. Every text part
  # is escaped here; the :safe tuple tells the Kit it is already HTML.
  defp rich(parts), do: {:safe, Enum.map(parts, &rich_part/1)}
  defp rich_part({:strong, text}), do: ["<strong>", escape(text), "</strong>"]
  defp rich_part({:code, text}), do: ["<code>", escape(text), "</code>"]

  defp rich_part({:time, %DateTime{} = at, text}) do
    [
      ~s(<time datetime="),
      DateTime.to_iso8601(at),
      ~s(" title="),
      escape(Calendar.strftime(at, "%d %b %Y, %H:%M UTC")),
      ~s(">),
      escape(text),
      "</time>"
    ]
  end

  defp rich_part(text) when is_binary(text), do: escape(text)
  defp escape(text), do: Plug.HTML.html_escape(to_string(text))

  # The same words as ShortTime on the other manage pages: minutes and hours
  # for today, "yesterday", then the date.
  defp ago(at, now) do
    seconds = DateTime.diff(now, at)

    cond do
      seconds < 60 -> "just now"
      seconds < 3_600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)} h ago"
      Date.diff(DateTime.to_date(now), DateTime.to_date(at)) == 1 -> "yesterday"
      true -> day(at, now)
    end
  end

  defp day(at, now) do
    if at.year == now.year,
      do: Calendar.strftime(at, "%-d %b"),
      else: Calendar.strftime(at, "%-d %b %Y")
  end

  @doc false
  def source_url(%{source_conversation_ref: "control-plane:lab:" <> id}) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> "/conversations/#{id}"
      :error -> nil
    end
  end

  def source_url(%{source_conversation_ref: "slack:" <> rest, source_message_ref: stamp}) do
    with [team, channel] <- String.split(rest, ":"),
         true <- Regex.match?(~r/\A[A-Z0-9]+\z/, team),
         true <- Regex.match?(~r/\A[A-Z0-9]+\z/, channel),
         true <- is_binary(stamp) && Regex.match?(~r/\A[0-9]+\.[0-9]+\z/, stamp) do
      "https://slack.com/app_redirect?" <>
        URI.encode_query(%{team: team, channel: channel, message_ts: stamp})
    else
      _ -> nil
    end
  end

  def source_url(_), do: nil
end
