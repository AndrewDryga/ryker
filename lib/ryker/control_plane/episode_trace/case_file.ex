defmodule Ryker.ControlPlane.EpisodeTrace.CaseFile do
  @moduledoc """
  The conversation the episode is about, as a reader sees it: the messages
  that came in with their retained bodies and provenance, the replies that
  went out, and the heading the whole page carries.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.ControlPlane.{CurrentInputs, ProviderMessage, SlackMarkdown}
  alias Ryker.ControlPlane.SourceText
  alias Ryker.Delivery.PlatformAction
  alias Ryker.Episodes.{Episode, RoutingDigests}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack.Names
  alias Ryker.Work.{Session, Turn}

  @doc """
  The case file: the latest messages and replies in display order, the
  page's title and repository, and whether a reply is still owed.
  """
  def build(episode_id, turns, sessions, disclosed) do
    options = [
      secrets: InspectionRedactor.configured_secrets(),
      max_bytes: 12_000,
      disclosed: disclosed
    ]

    base = from(entry in subquery(CurrentInputs.for_episode(episode_id)))

    first =
      Repo.one(from(entry in base, order_by: [asc: entry.occurred_at, asc: entry.id], limit: 1))

    first = if first, do: case_message(first, options)

    messages =
      Repo.all(
        from(entry in base, order_by: [desc: entry.occurred_at, desc: entry.id], limit: 20)
      )
      |> Enum.reverse()
      |> Enum.map(&case_message(&1, options))

    # The timeline shows each revision where it happened: the message as it was
    # sent, and an edit or deletion at the time it was made. The case file above
    # still reads as the conversation does now.
    revisions = episode_id |> revisions() |> Enum.map(&revision_message(&1, options))

    replies = turns |> Enum.flat_map(&case_reply(&1, options)) |> Enum.take(-20)
    updates = case_updates(episode_id, options)
    latest_reply = List.last(replies)
    current_turn = List.last(turns)

    task_session = task_session(current_turn, sessions)

    # The name Work gave the episode says what it became; a task's own title
    # and the first message are what is left before any turn has named it.
    {title_kind, title} =
      cond do
        title = episode_title(episode_id) -> {:episode, title}
        title = task_title(task_session) -> {:task, title}
        true -> {:request, input_title(first)}
      end

    %{
      title: title,
      title_kind: title_kind,
      expired_at: Enum.find_value(messages, & &1.expired_at),
      messages: messages,
      repository: case_repository(task_session, first),
      reply: latest_reply && latest_reply.text,
      reply_status: latest_reply && latest_reply.status,
      reply_request_id: latest_reply && latest_reply.id,
      awaiting_reply: is_nil(current_turn) or is_nil(current_turn.delivery_document),
      conversation:
        Enum.sort_by(
          revisions ++ Enum.filter(replies, & &1.delivered) ++ updates,
          & &1.at,
          DateTime
        )
    }
  end

  # The updates the Work model posted while it worked, where they reached the
  # conversation: before the answer of their turn, which is accepted only once
  # every update is delivered.
  defp case_updates(episode_id, options) do
    Repo.all(
      from(action in PlatformAction,
        where:
          action.episode_id == ^episode_id and action.tool == :post_slack_update and
            action.status == :delivered and not is_nil(action.delivered_at),
        order_by: [desc: action.delivered_at, desc: action.id],
        limit: 20
      )
    )
    |> Enum.reverse()
    |> Enum.map(fn action ->
      artifact = InspectionRedactor.artifact(action.document["message"], options)

      %{
        id: action.id,
        owner: {:turn, action.turn_id},
        at: action.delivered_at,
        actor: "Ryker",
        title: "Update",
        update: true,
        delivery_ref: action.action_ref,
        delivered: true,
        status: "Posted",
        text: artifact.text,
        available: artifact.state == :retained
      }
    end)
  end

  # Every revision this episode admitted, newest twenty, each beside the
  # current revision of its message, which may have arrived anywhere.
  defp revisions(episode_id) do
    entries =
      Repo.all(
        from(entry in Entry,
          where: entry.episode_id == ^episode_id,
          order_by: [desc: entry.occurred_at, desc: entry.id],
          limit: 20
        )
      )
      |> Enum.reverse()

    native_ids = entries |> Enum.map(& &1.native_input_id) |> Enum.uniq()

    current =
      Repo.all(
        from(entry in CurrentInputs.latest(),
          where: entry.native_input_id in ^native_ids,
          select: {{entry.execution_mode, entry.native_input_id}, {entry.id, entry.event_kind}}
        )
      )
      |> Map.new()

    Enum.map(entries, &{&1, current[{&1.execution_mode, &1.native_input_id}]})
  end

  defp revision_message({entry, current}, options) do
    message = case_message(entry, options)

    case current do
      {id, _kind} when id == entry.id -> message
      {_id, :delete} -> Map.put(message, :status, "Deleted later")
      {_id, _kind} -> Map.put(message, :status, "Replaced by an edit")
      nil -> message
    end
  end

  defp task_session(%Turn{operational_pruned_at: nil, session_id: id}, sessions),
    do: Enum.find(sessions, &(&1.id == id and is_map(&1.workspace_task)))

  defp task_session(_, _), do: nil

  defp episode_title(episode_id) do
    case RoutingDigests.titles([episode_id]) do
      %{^episode_id => title} -> InspectionRedactor.artifact(title, max_bytes: 240).text
      _untitled -> nil
    end
  end

  defp task_title(%Session{workspace_task: %{"title" => title}}) when is_binary(title),
    do: InspectionRedactor.artifact(title, max_bytes: 240).text

  defp task_title(_), do: nil

  defp input_title(%{available: true, text: text} = first),
    do: first_line(text, first[:workspace])

  defp input_title(_), do: "Untitled request"

  @doc """
  One message as the case file shows it, for a page about that message alone:
  who sent it and when, its retained words and their provenance. `disclosed`
  names the bodies the reader opened.
  """
  @spec input_message(Entry.t(), MapSet.t()) :: map()
  def input_message(%Entry{} = input, disclosed) do
    case_message(input,
      secrets: InspectionRedactor.configured_secrets(),
      max_bytes: 12_000,
      disclosed: disclosed
    )
  end

  @doc """
  A message's heading as people read it: its first line, the people and
  channels it mentions named from the Slack directory, never their raw ids.
  """
  @spec message_heading(map()) :: String.t()
  def message_heading(%{available: true, text: text} = message)
      when is_binary(text) and text != "",
      do: first_line(text, message[:workspace])

  def message_heading(_message), do: "Message text no longer available"

  defp first_line(text, workspace) do
    text
    |> String.trim_leading()
    |> String.split("\n", parts: 2)
    |> hd()
    |> SlackMarkdown.plain(workspace)
    |> bounded(120)
  end

  defp case_repository(%Session{repository_ref: ref}, _) when is_binary(ref), do: ref
  defp case_repository(_, first), do: first && first.repository

  @doc "The proposal, approval and failed start of a task that never ran, for a collapsed page."
  def task_start(episode, turn) do
    offer =
      Repo.one(
        from(record in Record,
          join: source in Episode,
          on: source.id == record.episode_id,
          where: record.kind == "task_offer" and record.status == :confirmed,
          where: record.confirmed_episode_id == ^episode.id,
          where: record.episode_id == ^(episode.linked_episode_id || episode.id),
          select: %{
            inserted_at: record.inserted_at,
            confirmed_at: record.confirmed_at,
            episode_key: source.key
          },
          order_by: [desc: record.confirmed_at, desc: record.id],
          limit: 1
        )
      )

    %{
      confirmed: not is_nil(offer) and not is_nil(offer.confirmed_at),
      events:
        Enum.reject(
          [
            offer &&
              %{
                label: "Task proposed",
                at: offer.inserted_at,
                href: "/timeline/" <> segment(offer.episode_key)
              },
            offer && offer.confirmed_at &&
              %{label: "Task approved", at: offer.confirmed_at, href: nil},
            %{
              label: "Couldn’t start — code-editing setup needs attention",
              at: turn.cancelled_at || turn.updated_at,
              href: nil
            }
          ],
          &is_nil/1
        )
    }
  end

  defp case_reply(
         %{operational_pruned_at: nil, delivery_document: %{"message" => text}} = turn,
         options
       )
       when is_binary(text) do
    artifact = InspectionRedactor.artifact(text, options)

    [
      %{
        id: turn.id,
        owner: {:turn, turn.id},
        at: turn.delivered_at || turn.accepted_at || turn.inserted_at,
        actor: "Ryker",
        delivery_ref: turn.delivery_ref,
        delivered: not is_nil(turn.delivered_at),
        status: case_reply_status(turn),
        text: artifact.text,
        available: artifact.state == :retained,
        href: "#request-#{turn.id}"
      }
    ]
  end

  defp case_reply(_, _), do: []

  defp case_message(input, options) do
    artifact =
      InspectionRedactor.artifact(
        if(is_nil(input.operational_pruned_at),
          do:
            if(input.event_kind == :delete,
              do: "Message deleted",
              else: SourceText.from_content(input.content)
            )
        ),
        Keyword.put(options, :expired, not is_nil(input.operational_pruned_at))
      )

    %{
      id: input.id,
      owner: {:input, input.id},
      at: input.occurred_at,
      transport: input.destination_transport,
      # "User" told a reader nothing they could act on. Slack writes a person as
      # @name, so the page does too, linked to their Slack profile and never as
      # a raw ID; an app or a bot there is named by Slack as well.
      actor: actor_label(input),
      person: slack_person(input),
      # People mentioned in the text are named while the card is drawn; the
      # names known then are part of the card, so a later one redraws it.
      names: Names.revision(),
      display_actor:
        if(input.source_kind == "slack" and input.actor_kind != :user,
          do: Names.name(input.source_ref, input.actor_ref)
        ),
      actor_ref: input.actor_ref,
      workspace: if(input.source_kind == "slack", do: input.source_ref),
      text: artifact.text,
      available: artifact.state == :retained,
      repository: input.repository_ref,
      expired_at: input.operational_pruned_at,
      href: "/timeline/ingress-input%3A#{input.id}",
      event_kind: input.event_kind,
      provider:
        if(is_nil(input.operational_pruned_at),
          do: ProviderMessage.recognize(input.source_kind, input.content)
        ),
      details: input_details(input, options)
    }
  end

  defp slack_person(%{actor_kind: :user, source_kind: "slack"} = input),
    do: Names.person(input.source_ref, input.actor_ref)

  defp slack_person(_input), do: nil

  defp actor_label(%{actor_kind: :user, source_kind: "slack"}), do: "Slack user"
  defp actor_label(%{actor_kind: :user, actor_ref: "local-operator"}), do: "You"
  defp actor_label(%{actor_kind: :user}), do: "User"
  defp actor_label(_input), do: "Source event"

  # Input details, in the approved order: readable extracted metadata first,
  # then the raw source envelope, the normalized input and the original message
  # as independently collapsed bodies. Raw is the adapter's payload; normalized
  # is what Ryker made of it; neither is ever shown under the other's name.
  defp input_details(input, options) do
    expired = not is_nil(input.operational_pruned_at)
    disclosed = Keyword.get(options, :disclosed, MapSet.new())
    raw_id = "input-#{input.id}-raw"
    normalized_id = "input-#{input.id}-normalized"

    %{
      metadata: input_metadata(input),
      raw: %{
        absent: raw_absent(input),
        artifact_id: raw_id,
        artifact: raw_envelope(input, expired, MapSet.member?(disclosed, raw_id), options)
      },
      normalized: %{
        artifact_id: normalized_id,
        artifact:
          InspectionRedactor.artifact(
            unless(expired, do: input.content),
            Keyword.merge(options,
              expired: expired,
              max_bytes: 64 * 1_024,
              disclosed: MapSet.member?(disclosed, normalized_id)
            )
          )
      }
    }
  end

  defp input_metadata(input) do
    compact_details([
      {"Input ID", "ingress-input:#{input.id}", identifier: true},
      {"Source", source_label(input.source_kind)},
      {"Sender ID", join_ref(input.actor_kind, input.actor_ref), identifier: true}
    ])
  end

  # A control-plane input is typed into Ryker itself, so no adapter stands
  # between the person and the record. Reporting that one failed to hand over a
  # payload blamed a hand-over that never happens for this source.
  defp raw_absent(%{source_kind: "control_plane"}),
    do: "This input was submitted directly in the control plane, so no adapter payload exists."

  defp raw_absent(_input),
    do:
      "The adapter did not hand over its source payload for this input, so there is no raw " <>
        "record; the normalized input below is not a substitute."

  defp raw_envelope(_input, true, _disclosed?, _options),
    do: %{state: :expired, text: nil, sha256: nil, bytes: nil, redacted: false, truncated: false}

  defp raw_envelope(%{source_envelope: nil}, _expired, _disclosed?, _options),
    do: %{
      state: :not_recorded,
      text: nil,
      sha256: nil,
      bytes: nil,
      redacted: false,
      truncated: false
    }

  defp raw_envelope(%{source_envelope: %{"omitted" => reason} = marker}, _expired, _d, _options)
       when map_size(marker) <= 3 do
    %{
      state: :omitted,
      reason: reason,
      omitted_bytes: marker["bytes"],
      text: nil,
      sha256: nil,
      bytes: nil,
      redacted: false,
      truncated: false
    }
  end

  defp raw_envelope(%{source_envelope: envelope}, _expired, disclosed?, options) do
    InspectionRedactor.artifact(
      envelope,
      Keyword.merge(options, max_bytes: 64 * 1_024, disclosed: disclosed?)
    )
  end

  defp source_label("slack"), do: "Slack"
  defp source_label("github"), do: "GitHub"
  defp source_label("control_plane"), do: "Direct conversation"
  defp source_label("webhook"), do: "Webhook"
  defp source_label(other), do: to_string(other)

  defp case_reply_status(%{
         delivered_at: %DateTime{},
         external_receipt: %{"message_ref" => "eval-message:" <> _}
       }),
       do: "Response captured in private replay"

  defp case_reply_status(%{delivered_at: %DateTime{}}), do: "Response sent"
  defp case_reply_status(%{accepted_at: %DateTime{}}), do: "Accepted · delivery not confirmed"
  defp case_reply_status(_turn), do: nil
end
