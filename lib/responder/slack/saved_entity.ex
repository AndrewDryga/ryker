defmodule Responder.Slack.SavedEntity do
  @moduledoc """
  One reusable detail projection for saved schedules, standing rules,
  preferences, guidance and memories.

  A confirmed offer, an updated automation and a requested collection item all
  render this same document: a stable title, the full readable purpose, real
  metadata, a brief event or status notice, and the exact-resource removal
  control. Raw identifiers and enum values are translated to labels; nothing
  that the entity does not retain is invented.
  """

  alias Responder.State.{Behavior, MemoryEntry, Schedule}

  @type event :: :saved | :updated | nil

  @spec document(Schedule.t() | Behavior.t() | MemoryEntry.t(), event()) :: map()
  def document(entity, event \\ nil)

  def document(%Schedule{} = schedule, event) do
    status = Atom.to_string(schedule.status)

    %{
      "facts" =>
        facts([
          {"When", "#{recurrence(schedule.recurrence)} · #{schedule.timezone}"},
          {"Channel", destination(schedule.destination_conversation_ref)},
          {"Next run", next_run(schedule)},
          {"Expires", expiry(schedule.expires_at, "No expiry")},
          {"Missed runs", catch_up(schedule.catch_up)},
          {"Access", authority(schedule.authority)},
          {"Repository", schedule.repository || "No fixed binding"}
        ]),
      "instructions" => schedule.task,
      "kind" => "schedule",
      "notice" => notice("Schedule", status, event),
      "ref" => schedule.ref,
      "removable" => status in ~w(active paused),
      "revision" => schedule.revision,
      "saved_at" => DateTime.to_iso8601(schedule.confirmed_at),
      "saved_by" => schedule.confirmed_by_actor_ref,
      "status" => status,
      "title" => schedule.title
    }
  end

  def document(%Behavior{kind: :standing_assignment} = behavior, event) do
    payload = behavior.payload

    facts =
      case payload do
        %{"source_kind" => source_kind} ->
          [
            {"Channel", destination(payload["context_channel"])},
            {"Source", source_kind},
            {"Event filter", event_filter(source_kind, payload["filter"])},
            {"Repository", payload["repository"] || "No fixed binding"},
            {"Expires", expiry(behavior.expires_at, "Until disabled")},
            {"Missed events", catch_up(payload["catch_up"])},
            {"Access", "Read-only"}
          ]

        _trigger ->
          [
            {"Trigger", "#{payload["trigger"]} → #{payload["action"]}"},
            {"Source filter", payload["source_filter"]},
            {"Repository", payload["repository"] || "No fixed binding"},
            {"Expires", expiry(behavior.expires_at, "Until disabled")},
            {"Access", "Read-only"}
          ]
      end

    behavior_document(
      behavior,
      "standing_rule",
      "Standing rule",
      payload["title"] || payload["trigger"] || behavior.identity_key,
      payload["task"],
      facts,
      event
    )
  end

  def document(%Behavior{kind: :preference} = behavior, event) do
    payload = behavior.payload

    behavior_document(
      behavior,
      "preference",
      "Preference",
      payload["key"],
      "#{payload["key"]} = #{payload["value"]}",
      [
        {"Scope", scope(behavior.scope_kind, behavior.scope_ref)},
        {"Repository", payload["repository"] || "No fixed binding"},
        {"Expires", expiry(behavior.expires_at, "Until removed")}
      ],
      event
    )
  end

  def document(%Behavior{kind: :guidance} = behavior, event) do
    payload = behavior.payload

    behavior_document(
      behavior,
      "guidance",
      "Guidance",
      payload["subject"],
      payload["text"],
      [
        {"Scope", scope(behavior.scope_kind, behavior.scope_ref)},
        {"Repository", payload["repository"] || "No fixed binding"},
        {"Visibility", visibility(payload["visibility"])},
        {"Expires", expiry(behavior.expires_at, "Until removed")},
        {"Source", source(behavior)}
      ],
      event
    )
  end

  def document(%MemoryEntry{} = entry, event) do
    status = Atom.to_string(entry.status)

    %{
      "facts" =>
        facts([
          {"Kind", memory_kind(entry.kind)},
          {"Scope", scope(entry.scope_kind, entry.scope_ref)},
          {"Visibility", visibility(Atom.to_string(entry.visibility))},
          {"Expires", expiry(entry.expires_at, "No expiry")},
          {"Source", source(entry)}
        ]),
      "instructions" => entry.payload["value"],
      "kind" => "memory",
      "notice" => notice("Memory", status, event),
      "ref" => entry.ref,
      "removable" => status == "active",
      "revision" => nil,
      "saved_at" => DateTime.to_iso8601(entry.confirmed_at),
      "saved_by" => entry.confirmed_by_actor_ref,
      "status" => status,
      "title" => entry.subject
    }
  end

  defp behavior_document(behavior, kind, label, title, instructions, facts, event) do
    status = Atom.to_string(behavior.status)

    %{
      "facts" => facts(facts),
      "instructions" => instructions,
      "kind" => kind,
      "notice" => notice(label, status, event),
      "ref" => behavior.ref,
      "removable" => status in ~w(active disabled),
      "revision" => behavior.revision,
      "saved_at" => DateTime.to_iso8601(behavior.confirmed_at),
      "saved_by" => behavior.confirmed_by_actor_ref,
      "status" => status,
      "title" => title
    }
  end

  defp facts(pairs) do
    pairs
    |> Enum.reject(fn {_label, value} -> is_nil(value) end)
    |> Enum.map(&Tuple.to_list/1)
  end

  # The notice names the event when the entity is still live; once it is gone
  # the current state matters more than what happened when it was saved.
  defp notice(label, status, :saved) when status in ~w(active paused disabled),
    do: "#{label} saved"

  defp notice(label, status, :updated) when status in ~w(active paused disabled),
    do: "#{label} has been updated"

  defp notice(label, "active", nil), do: "#{label} active"
  defp notice(label, status, _event) when status in ~w(paused disabled), do: "#{label} paused"
  defp notice(label, "completed", _event), do: "#{label} completed"
  defp notice(label, "expired", _event), do: "#{label} expired"
  defp notice(label, "deleted", _event), do: "#{label} deleted"
  defp notice(label, "superseded", _event), do: "#{label} replaced by a newer version"

  defp recurrence(%{"kind" => "once", "at" => at}), do: "Once at #{at}"

  defp recurrence(%{"kind" => "interval", "every_seconds" => seconds} = recurrence) do
    "Every #{seconds} seconds" <>
      if(recurrence["starts_at"], do: " from #{recurrence["starts_at"]}", else: "")
  end

  defp recurrence(%{"kind" => "daily", "time" => time}), do: "Daily at #{time}"

  defp recurrence(%{"kind" => "weekly", "weekday" => weekday, "time" => time}),
    do: "Every #{weekday} at #{time}"

  defp recurrence(%{"kind" => "monthly", "day" => day, "time" => time}),
    do: "Monthly on day #{day} at #{time}"

  defp recurrence(_recurrence), do: "Not recorded"

  defp next_run(%Schedule{status: :active, next_occurrence_at: %DateTime{} = at}),
    do: time(at)

  defp next_run(_schedule), do: nil

  defp catch_up(:latest), do: "Run the latest missed occurrence"
  defp catch_up("latest"), do: "Run the latest missed occurrence"
  defp catch_up(:skip), do: "Skip missed occurrences"
  defp catch_up("skip"), do: "Skip missed occurrences"
  defp catch_up(_other), do: nil

  defp authority(:read_only), do: "Read-only"
  defp authority(:repository_write), do: "Repository write"
  defp authority(:governed_operation), do: "Governed operation"

  # A Slack destination is a typed channel reference so the renderer can emit
  # a real channel mention; anything else stays escaped text.
  defp destination("slack:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [_workspace_ref, channel_ref] -> %{"channel_ref" => channel_ref}
      _invalid -> rest
    end
  end

  defp destination(value), do: value

  # An empty filter means every event of that source posted in the channel.
  defp event_filter(source_kind, filter) when filter in [nil, %{}],
    do: "All #{source_kind} events posted here"

  defp event_filter(_source_kind, filter), do: Jason.encode!(filter)

  defp source(%{source_transport: "slack", source_conversation_ref: conversation_ref})
       when is_binary(conversation_ref),
       do: destination(conversation_ref)

  defp source(%{source_transport: transport}) when is_binary(transport),
    do: "Request through #{transport}"

  defp source(_entity), do: nil

  defp scope(:workspace, _ref), do: "Whole workspace"
  defp scope(:global, _ref), do: "Every installation"
  defp scope(:conversation, _ref), do: "This conversation"
  defp scope(:repository, ref), do: "Repository #{ref}"
  defp scope(:operator, ref), do: "Operator #{ref}"

  defp visibility("private"), do: "Private to the operator"
  defp visibility("conversation"), do: "This conversation"
  defp visibility("workspace"), do: "Whole workspace"
  defp visibility("global"), do: "Every installation"
  defp visibility(other), do: other

  defp memory_kind(kind), do: kind |> Atom.to_string() |> String.replace("_", " ")

  defp expiry(%DateTime{} = at, _default), do: time(at)
  defp expiry(nil, default), do: default

  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y, %H:%M UTC")
end
