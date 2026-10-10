defmodule Ryker.Slack.SavedEntity do
  @moduledoc """
  One reusable detail projection for saved schedules, standing rules,
  preferences, guidance and memories.

  A confirmed offer, an updated automation and a requested collection item all
  render this same document: a stable title, the readable purpose (its first
  2,000 bytes, with "…" when there is more), real metadata, a brief event or
  status notice, and the exact-resource removal control. Raw identifiers and enum values are translated to labels; nothing
  that the entity does not retain is invented.
  """
  alias Ryker.Behaviors
  alias Ryker.ConversationRef
  alias Ryker.Delivery
  alias Ryker.GitHub
  alias Ryker.Memories
  alias Ryker.Schedules
  alias Ryker.Settings
  alias Ryker.Wording

  @shown_bytes 2_000

  @type event :: :saved | :updated | nil

  @spec document(
          Schedules.Schedule.t() | Behaviors.Behavior.t() | Memories.MemoryEntry.t(),
          event()
        ) :: map()
  def document(entity, event \\ nil)

  def document(%Schedules.Schedule{} = schedule, event) do
    status = Atom.to_string(schedule.status)

    %{
      "facts" =>
        facts([
          {"When", Schedules.ScheduleCadence.describe(schedule.recurrence, schedule.timezone)},
          {"Channel", destination(schedule.destination_conversation_ref)},
          {"Next run", next_run(schedule)},
          {"Expires", expiry(schedule.expires_at, "No expiry")},
          {"Access", authority(schedule.authority)},
          {"Repository", repository(schedule.repository)}
        ]),
      "instructions" => shown(schedule.task),
      "kind" => "schedule",
      "notice" => notice("Schedule", status, event),
      "ref" => schedule.ref,
      "removable" => status in ~w(active paused),
      "resumable" => false,
      "revision" => schedule.revision,
      "saved_at" => DateTime.to_iso8601(schedule.confirmed_at),
      "saved_by" => schedule.confirmed_by_actor_ref,
      "status" => status,
      "title" => schedule.title
    }
  end

  def document(%Behaviors.Behavior{} = behavior, event) do
    if Behaviors.redacted?(behavior.payload),
      do: ended_document(behavior, event),
      else: kept_document(behavior, event)
  end

  def document(%Memories.MemoryEntry{} = entry, event) do
    status = Atom.to_string(entry.status)

    %{
      "facts" =>
        facts(
          [{"Kind", memory_kind(entry.kind)}] ++
            audience(
              scope(entry.scope_kind, entry.scope_ref),
              visibility(Atom.to_string(entry.visibility))
            ) ++
            [
              {"Expires", expiry(entry.expires_at, "No expiry")},
              {"Source", source(entry)}
            ]
        ),
      "instructions" => shown(entry.payload["value"]),
      "kind" => "memory",
      "notice" => notice("Memory", status, event),
      "ref" => entry.ref,
      "removable" => status == "active",
      "resumable" => false,
      "revision" => nil,
      "saved_at" => DateTime.to_iso8601(entry.confirmed_at),
      "saved_by" => entry.confirmed_by_actor_ref,
      "status" => status,
      "title" => entry.subject
    }
  end

  # Deleted or replaced, a rule, preference or guidance keeps no words
  # (`Ryker.Behaviors.redact!/3`), so its card names only what it was and that
  # it is gone.
  defp ended_document(%Behaviors.Behavior{kind: kind} = behavior, event) do
    {card, label} =
      case kind do
        :standing_assignment -> {"standing_rule", "Standing rule"}
        :preference -> {"preference", "Preference"}
        :guidance -> {"guidance", "Guidance"}
      end

    behavior_document(behavior, card, label, label, nil, [], event)
  end

  defp kept_document(%Behaviors.Behavior{kind: :standing_assignment} = behavior, event) do
    payload = behavior.payload

    facts = [
      {"Channel", destination(payload["context_channel"])},
      {"Source", payload["source_kind"]},
      {"Event filter", event_filter(payload["source_kind"], payload["filter"])},
      {"Repository", repository(payload["repository"])},
      {"Expires", expiry(behavior.expires_at, "Until disabled")},
      {"Access", "Read-only"}
    ]

    behavior_document(
      behavior,
      "standing_rule",
      "Standing rule",
      payload["title"] || behavior.identity_key,
      payload["task"],
      facts,
      event
    )
  end

  defp kept_document(%Behaviors.Behavior{kind: :preference} = behavior, event) do
    payload = behavior.payload

    # In words: the card read "response_detail = standard" (2026-10-10).
    behavior_document(
      behavior,
      "preference",
      "Preference",
      Delivery.OfferWords.humanize(payload["key"]),
      Delivery.OfferWords.humanize(payload["value"]),
      [
        {"Applies to", scope(behavior.scope_kind, behavior.scope_ref)},
        {"Repository", repository(payload["repository"])},
        {"Expires", expiry(behavior.expires_at, "Until removed")}
      ],
      event
    )
  end

  defp kept_document(%Behaviors.Behavior{kind: :guidance} = behavior, event) do
    payload = behavior.payload

    behavior_document(
      behavior,
      "guidance",
      "Guidance",
      payload["subject"],
      payload["text"],
      audience(scope(behavior.scope_kind, behavior.scope_ref), visibility(payload["visibility"])) ++
        [
          {"Repository", repository(payload["repository"])},
          {"Expires", expiry(behavior.expires_at, "Until removed")},
          {"Source", source(behavior)}
        ],
      event
    )
  end

  defp behavior_document(behavior, kind, label, title, instructions, facts, event) do
    status = Atom.to_string(behavior.status)

    %{
      "facts" => facts(facts),
      "instructions" => shown(instructions),
      "kind" => kind,
      "notice" => notice(label, status, event),
      "ref" => behavior.ref,
      "removable" => status in ~w(active disabled),
      # A paused standing rule governs nothing until someone restarts it, and
      # App Home was the only surface that could — one most readers of a
      # channel's rule list cannot act in. Preferences and guidance keep their
      # existing single control; this row is about rules.
      "resumable" => kind == "standing_rule" and status == "disabled",
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

  # A time is the moment itself, which Slack shows in each reader's own time.
  defp next_run(%Schedules.Schedule{status: :active, next_occurrence_at: %DateTime{} = at}),
    do: %{"at" => DateTime.to_iso8601(at)}

  defp next_run(_schedule), do: nil

  # In the words the schedule's offer used ("Can change code in …").
  defp authority(:read_only), do: "Read-only"
  defp authority(:repository_write), do: "Can change code"
  defp authority(:governed_operation), do: "Can run approved operations"

  # A repository by the name GitHub gives it, as a link, or by the ref Ryker
  # keeps once it no longer has it; nothing when the entity names none.
  defp repository(nil), do: nil

  defp repository(ref) do
    case Settings.github_repository(ref) do
      name when is_binary(name) -> %{"ref" => ref, "url" => GitHub.repository_url(name)}
      _unknown -> %{"ref" => ref, "url" => nil}
    end
  end

  # A Slack destination is a typed channel reference so the renderer can emit
  # a real channel mention; anything else stays escaped text.
  defp destination("slack:" <> rest = conversation_ref) do
    case ConversationRef.parse_slack(conversation_ref) do
      {:ok, _workspace_ref, channel_ref} -> %{"channel_ref" => channel_ref}
      :error -> rest
    end
  end

  defp destination(value), do: value

  # An empty filter means every event of that source posted in the channel.
  defp event_filter(source_kind, filter) when filter in [nil, %{}],
    do: "All #{source_kind} events posted here"

  # In the words the rule's offer used; the saved rule showed raw JSON
  # (2026-10-04 review).
  defp event_filter(_source_kind, filter), do: Delivery.OfferWords.only_when(filter)

  defp source(%{source_transport: "slack", source_conversation_ref: conversation_ref})
       when is_binary(conversation_ref),
       do: destination(conversation_ref)

  defp source(%{source_transport: transport}) when is_binary(transport),
    do: "Request through #{transport}"

  defp source(_entity), do: nil

  @doc """
  What kind of fact was saved, in words: the card said "entity relationship"
  (Slack as Andrew, 2026-10-09).
  """
  @spec memory_kind(atom()) :: String.t()
  def memory_kind(:entity_relationship), do: "Fact"
  def memory_kind(:alias), do: "Another name"
  def memory_kind(:repository_binding), do: "Repository for this work"
  def memory_kind(:evidence_route), do: "Where to look"
  def memory_kind(kind), do: Wording.label(kind)

  # Whom it applies to, said once when it is also who sees it: the card said
  # "This conversation" twice, as Scope and as Visibility.
  defp audience(applies, applies), do: [{"Applies to", applies}]
  defp audience(applies, sees), do: [{"Applies to", applies}, {"Who sees it", sees}]

  defp scope(:workspace, _ref), do: "Whole workspace"
  defp scope(:global, _ref), do: "Everywhere"
  defp scope(:conversation, _ref), do: "This conversation"
  defp scope(:repository, ref), do: "Repository " <> Settings.repository_name(ref)
  defp scope(:operator, _ref), do: "Just the person who saved it"

  defp visibility("private"), do: "Just the person who saved it"
  defp visibility("conversation"), do: "This conversation"
  defp visibility("workspace"), do: "Whole workspace"
  defp visibility("global"), do: "Everywhere"
  defp visibility(other), do: other

  defp expiry(%DateTime{} = at, _default), do: %{"at" => DateTime.to_iso8601(at)}
  defp expiry(nil, default), do: default

  # A schedule or rule holds up to 12,000 bytes; its card shows the first 2,000,
  # its renderer's bound. The whole text stays saved (2026-10-04 review: a
  # longer one made the card invalid).
  defp shown(nil), do: nil
  defp shown(text) when is_binary(text), do: Ryker.Text.cut(text, @shown_bytes)
end
