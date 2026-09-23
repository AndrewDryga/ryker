defmodule Ryker.ControlPlane.EpisodeTrace.CaseFile do
  @moduledoc """
  The conversation the episode is about, as a reader sees it: the messages
  that came in with their retained bodies and provenance, the replies that
  went out, and the heading the whole page carries.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.ControlPlane.{CurrentInputs, InspectionRedactor, ProviderMessage, SlackMarkdown}
  alias Ryker.ControlPlane.SlackNames
  alias Ryker.ControlPlane.SourceText
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.State.Record
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

    replies = turns |> Enum.flat_map(&case_reply(&1, options)) |> Enum.take(-20)
    latest_reply = List.last(replies)
    current_turn = List.last(turns)

    task_session = task_session(current_turn, sessions)

    %{
      title: task_title(task_session) || input_title(first),
      expired_at: Enum.find_value(messages, & &1.expired_at),
      messages: messages,
      repository: case_repository(task_session, first),
      reply: latest_reply && latest_reply.text,
      reply_status: latest_reply && latest_reply.status,
      reply_request_id: latest_reply && latest_reply.id,
      awaiting_reply: is_nil(current_turn) or is_nil(current_turn.delivery_document),
      conversation:
        Enum.sort_by(messages ++ Enum.filter(replies, & &1.delivered), & &1.at, DateTime)
    }
  end

  defp task_session(%Turn{operational_pruned_at: nil, session_id: id}, sessions),
    do: Enum.find(sessions, &(&1.id == id and is_map(&1.workspace_task)))

  defp task_session(_, _), do: nil

  defp task_title(%Session{workspace_task: %{"title" => title}}) when is_binary(title),
    do: InspectionRedactor.artifact(title, max_bytes: 240).text

  defp task_title(_), do: nil

  defp input_title(%{available: true, text: text} = first) do
    text
    |> String.split("\n", parts: 2)
    |> hd()
    |> SlackMarkdown.plain(first[:workspace])
    |> bounded(120)
  end

  defp input_title(_), do: "Episode case file"

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
      # @name, so the page does too, and says which workspace they are from.
      actor: actor_label(input),
      display_actor:
        if(input.source_kind == "slack",
          do: SlackNames.name(input.source_ref, input.actor_ref)
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

  defp actor_label(%{actor_kind: :user, source_kind: "slack"}), do: "Slack user"
  defp actor_label(%{actor_kind: :user, actor_ref: "local-operator"}), do: "Local operator"
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

  @doc """
  The heading a message carries before it becomes an episode.

  The same sentence the episode page shows for a case file: the request itself,
  shortened, and redacted the way every other retained text is.
  """
  @spec unrouted_title(Entry.t()) :: String.t()
  def unrouted_title(%Entry{operational_pruned_at: nil, content: content}) do
    case SourceText.from_content(content) do
      text when is_binary(text) and text != "" ->
        InspectionRedactor.artifact(text, max_bytes: 160).text

      _absent ->
        "Message waiting on routing"
    end
  end

  def unrouted_title(%Entry{}), do: "Message waiting on routing"
end
