defmodule Ryker.ControlPlane.EpisodeProjection do
  @moduledoc """
  One episode's page: durable lifecycle metadata, its bounded event and record
  windows, the trace `EpisodeTrace` builds from them, its accounting and the
  episodes it is linked to. Raw ingress bodies, prompts and payloads never
  cross this boundary.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{Activity, EpisodeTrace, ModelRequests, UsageProjection}
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Repo
  alias Ryker.State.Record

  @record_limit 500

  @doc "The reader-facing key of an episode by id, or nil when there is no such episode."
  @spec key(Ecto.UUID.t() | nil) :: String.t() | nil
  def key(nil), do: nil

  def key(id) do
    Repo.one(from(episode in Episode, where: episode.id == ^id, select: episode.key, limit: 1))
  end

  @doc "One episode page: lifecycle metadata, bounded events and records, trace, accounting and links."
  def fetch(ref, params \\ %{})

  def fetch(ref, params) when is_binary(ref) and byte_size(ref) <= 1_024 and is_map(params) do
    ref = ModelRequests.episode_ref(ref)

    case Repo.one(from(episode in Episode, where: episode.key == ^ref)) do
      nil ->
        :not_found

      episode ->
        event_records =
          Repo.all(
            from(event in Event,
              where: event.episode_id == ^episode.id,
              order_by: [desc: event.sequence],
              limit: 500
            )
          )
          |> Enum.reverse()

        events =
          Enum.map(event_records, fn event ->
            %{
              kind: event.kind,
              occurred_at: event.occurred_at,
              summary: event_summary(event.kind)
            }
          end)

        record_records =
          Repo.all(
            from(record in Record,
              where: record.episode_id == ^episode.id,
              order_by: [desc: record.sequence, desc: record.id],
              limit: @record_limit
            )
          )
          |> Enum.reverse()

        records =
          Enum.map(record_records, fn record ->
            %{
              kind: record.kind,
              status: record.status,
              summary: record_summary(record)
            }
          end)

        trace =
          EpisodeTrace.project(episode, event_records, record_records,
            disclosed: ModelRequests.disclosed(params),
            activity_pages: activity_pages(params)
          )

        accounting =
          Ryker.Accounting.Query.executions(nil, "all")
          |> where([execution], execution.episode_id == ^episode.id)
          |> UsageProjection.totals()

        {:ok,
         %{
           episode: %{
             created_at: episode.inserted_at,
             destination: destination(episode),
             conversation_ref: episode.destination_conversation_ref,
             thread_ref: episode.destination_thread_ref,
             # Set once retention removed the kernel events and closed records;
             # an empty timeline after that is expiry, not an episode that
             # never did anything.
             history_pruned_at: episode.history_pruned_at,
             # The identity a card needs to read evidence recorded against this
             # episode; the key is the reader-facing reference and cannot be
             # joined on.
             id: episode.id,
             transport: episode.destination_transport,
             next_action: trace.next_action,
             ref: episode.key,
             state: episode.state,
             updated_at: episode.updated_at
           },
           events: events,
           records: records,
           related_episodes: related_episodes(episode),
           accounting: accounting,
           trace: trace
         }}
    end
  end

  def fetch(_ref, _params), do: :not_found

  # Loading older activity is an explicit, bounded step the reader takes. The
  # page keeps its position: the events already read are still the same rows
  # with the same identities, with older ones appended before them.
  defp activity_pages(%{"events" => value}) when is_binary(value) do
    case Integer.parse(value) do
      {pages, ""} when pages in 1..10 -> pages
      _invalid -> 1
    end
  end

  defp activity_pages(_params), do: 1

  defp related_episodes(episode) do
    related =
      Repo.all(
        from(other in Episode,
          where: other.destination_transport == ^episode.destination_transport,
          where: other.destination_conversation_ref == ^episode.destination_conversation_ref,
          where:
            other.linked_episode_id == ^episode.id or
              other.id == ^(episode.linked_episode_id || episode.id),
          where: other.id != ^episode.id,
          order_by: [asc: other.inserted_at, asc: other.id],
          limit: 21
        )
      )

    titles = Activity.request_titles(Enum.map(related, & &1.key))

    %{
      truncated: length(related) > 20,
      items:
        Enum.map(Enum.take(related, 20), fn other ->
          %{
            ref: other.key,
            title: get_in(titles, [other.key, :title]) || "Earlier request",
            href: "/timeline/" <> URI.encode_www_form(other.key),
            at: other.inserted_at,
            state: other.state,
            relation:
              if(other.id == episode.linked_episode_id,
                do: "Previous episode",
                else: "Follow-up episode"
              )
          }
        end)
    }
  end

  defp destination(episode) do
    case episode.destination_thread_ref do
      nil ->
        "#{episode.destination_transport}:#{episode.destination_conversation_ref}"

      thread ->
        "#{episode.destination_transport}:#{episode.destination_conversation_ref}:#{thread}"
    end
  end

  defp event_summary(kind) do
    kind |> Atom.to_string() |> String.replace("_", " ")
  end

  defp record_summary(%Record{subject_ref: subject}) when is_binary(subject), do: subject
  defp record_summary(%Record{operation_id: operation}), do: operation
end
