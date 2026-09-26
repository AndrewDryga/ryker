defmodule Ryker.ControlPlane.ThreadContext do
  @moduledoc """
  The messages around one message in its Slack thread or Chat conversation,
  for the page of a message that started no request of its own.

  Routing answers a greeting itself and starts nothing, so each such message
  has a page of its own, and without its neighbours every one of them read as
  if it stood alone (Andrew, 2026-09-26: "not joined to an episode so each
  message looks separate, is that normal?"). This is the thread as people
  wrote it: the messages nearest this one, oldest first, each once however
  many times it was edited or delivered, with what came of it and where to
  read more — its own page, or the request it started or joined.
  """

  import Ecto.Query
  require Ryker.ControlPlane.CurrentInputs

  alias Ryker.ControlPlane.{Activity, ActivityPage, CurrentInputs, Kit, SourceText}
  alias Ryker.ControlPlane.EpisodeTrace.CaseFile
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.Repo
  alias Ryker.Slack.Names

  @limit 20
  # Every revision and duplicate delivery of the listed messages; far more
  # than any message has, and never the whole table.
  @entry_limit 500

  @type item :: %{
          id: String.t(),
          name: String.t(),
          href: String.t() | nil,
          current: boolean(),
          state: {atom(), String.t()},
          at: DateTime.t(),
          clock: String.t(),
          group: String.t() | nil,
          meta: [String.t()]
        }

  @doc """
  The thread around `entry`: at most #{@limit} messages nearest it, this one
  among them, or nil when it is the only message there.
  """
  @spec around(Entry.t(), DateTime.t()) :: map() | nil
  def around(entry, now \\ DateTime.utc_now())

  def around(%Entry{destination_thread_ref: thread} = entry, now) when is_binary(thread) do
    place = place(entry)
    anchor = first_sent(place, entry.native_input_id) || entry.occurred_at
    nearest = nearest(place, anchor)

    if length(nearest) > 1 do
      shown = Enum.take(nearest, @limit)
      items = items(place, Enum.map(shown, & &1.native_input_id), entry, now)
      heading(entry, items, length(nearest) > @limit, now)
    end
  end

  def around(_entry, _now), do: nil

  defp heading(entry, items, truncated, now) do
    days = Kit.day_groups(items, & &1.at, now)
    slack? = entry.destination_transport == "slack"

    %{
      title: if(slack?, do: "In this thread", else: "In this conversation"),
      lede:
        if(slack?,
          do:
            "The messages in this Slack thread, oldest first. Each opens its own page, or the request it started or joined.",
          else:
            "The messages in this conversation, oldest first. Each opens its own page, or the request it started or joined."
        ),
      items: items |> Enum.zip(days) |> Enum.map(fn {item, day} -> %{item | group: day} end),
      truncated: truncated,
      limit: @limit,
      all_label:
        if(slack?, do: "All activity in this thread", else: "All activity in this conversation"),
      all_href:
        Activity.conversation_path(
          entry.destination_transport,
          entry.destination_conversation_ref,
          entry.destination_thread_ref
        )
    }
  end

  defp place(entry) do
    dynamic(
      [message],
      message.destination_transport == ^entry.destination_transport and
        message.destination_conversation_ref == ^entry.destination_conversation_ref and
        message.destination_thread_ref == ^entry.destination_thread_ref and
        message.execution_mode == ^entry.execution_mode
    )
  end

  # A message sits in the thread where it was first sent; an edit made later
  # does not move it.
  defp first_sent(place, native_input_id) do
    Repo.one(
      from(message in Entry,
        where: ^place,
        where: message.native_input_id == ^native_input_id,
        select: min(message.occurred_at)
      )
    )
  end

  defp nearest(place, anchor) do
    messages =
      from(message in Entry,
        where: ^place,
        group_by: message.native_input_id,
        select: %{native_input_id: message.native_input_id, at: min(message.occurred_at)}
      )

    Repo.all(
      from(message in subquery(messages),
        order_by: [
          asc:
            fragment(
              "abs(extract(epoch from (? - ?)))",
              message.at,
              type(^anchor, :utc_datetime_usec)
            ),
          asc: message.at,
          asc: message.native_input_id
        ],
        limit: ^(@limit + 1)
      )
    )
  end

  defp items(place, native_input_ids, entry, now) do
    entries =
      Repo.all(
        from(message in Entry,
          left_join: episode in Episode,
          on: episode.id == message.episode_id,
          where: ^place,
          where: message.native_input_id in ^native_input_ids,
          order_by: [asc: message.revision, asc: message.inserted_at, asc: message.id],
          limit: @entry_limit,
          select: %{
            id: message.id,
            native_input_id: message.native_input_id,
            revision: message.revision,
            occurred_at: message.occurred_at,
            status: message.status,
            state: CurrentInputs.input_state(message, ^now),
            episode_key: episode.key,
            content: message.content,
            event_kind: message.event_kind,
            pruned_at: message.operational_pruned_at,
            source_kind: message.source_kind,
            source_ref: message.source_ref,
            actor_kind: message.actor_kind,
            actor_ref: message.actor_ref
          }
        )
      )

    requests =
      entries
      |> Enum.map(& &1.episode_key)
      |> Enum.reject(&is_nil/1)
      |> Activity.request_titles()

    secrets = InspectionRedactor.configured_secrets()

    entries
    |> Enum.group_by(& &1.native_input_id)
    |> Enum.map(fn {native_input_id, revisions} ->
      item(revisions, native_input_id == entry.native_input_id, requests, secrets)
    end)
    |> Enum.sort_by(& &1.at, DateTime)
  end

  # Revisions arrive oldest first: the last is what the message says now.
  defp item(revisions, current, requests, secrets) do
    latest = List.last(revisions)
    {href, state, relation} = outcome(revisions, requests)
    at = revisions |> Enum.map(& &1.occurred_at) |> Enum.min(DateTime)

    %{
      id: "thread-message-#{latest.id}",
      name: heading_text(latest, secrets),
      href: if(current, do: nil, else: href),
      current: current,
      state: ActivityPage.state(state),
      at: at,
      clock: Kit.clock(at) <> " UTC",
      group: nil,
      meta: Enum.reject([sender(latest), relation], &is_nil/1)
    }
  end

  # A message that started or joined a request is read on the request's page,
  # in the words Activity uses for it. One that did not is read on its own
  # page: the latest version, and of two deliveries of it the one routing
  # decided, since that is what the thread saw.
  defp outcome(revisions, requests) do
    case revisions |> Enum.filter(& &1.episode_key) |> List.last() do
      %{episode_key: key} ->
        started = Enum.any?(revisions, &(key == "ingress-input:#{&1.id}"))

        {"/timeline/" <> URI.encode_www_form(key), request_state(requests[key]),
         if(started, do: "Started a request", else: "Added to a request")}

      nil ->
        latest = List.last(revisions).revision
        copies = Enum.filter(revisions, &(&1.revision == latest))
        shown = Enum.find(copies, &(&1.status == :decided)) || List.last(copies)

        {"/timeline/" <> URI.encode_www_form("ingress-input:#{shown.id}"), shown.state, nil}
    end
  end

  defp request_state(%{state: state}), do: state
  defp request_state(nil), do: "working"

  defp heading_text(message, secrets) do
    text =
      cond do
        not is_nil(message.pruned_at) -> nil
        message.event_kind == :delete -> "Message deleted"
        true -> SourceText.from_content(message.content)
      end

    artifact = InspectionRedactor.artifact(text, secrets: secrets, max_bytes: 12_000)

    CaseFile.message_heading(%{
      available: artifact.state == :retained,
      text: artifact.text,
      workspace: if(message.source_kind == "slack", do: message.source_ref)
    })
  end

  defp sender(%{source_kind: "slack", actor_kind: :user} = message),
    do: Names.person(message.source_ref, message.actor_ref).name

  defp sender(%{source_kind: "slack"} = message),
    do: Names.name(message.source_ref, message.actor_ref)

  defp sender(%{actor_kind: :user, actor_ref: "local-operator"}), do: "You"
  defp sender(_message), do: nil
end
