defmodule Ryker.ControlPlane.EpisodeProjection do
  @moduledoc """
  One episode's page: durable lifecycle metadata, its bounded event and record
  windows, the trace `EpisodeTrace` builds from them, its accounting and the
  episodes it is linked to. Raw ingress bodies, prompts and payloads never
  cross this boundary. An open page redraws when the request, its
  conversation or background learning changes (`subscriptions/1`).
  """
  alias Ryker.Accounting
  alias Ryker.ControlPlane.{Activity, EpisodeTrace, FeedbackProjection}
  alias Ryker.ControlPlane.{ImprovementRequests, ModelRequests, Paths, TaskProgress}
  alias Ryker.ControlPlane.UsageProjection
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Learning
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Wording

  @record_limit 500

  # A request's page and a message's page show the learning passes over their
  # messages; learning announces them on its own topic.
  @learning {Learning, :subscribe_learning, []}

  @doc "The reader-facing key of an episode by id, or nil when there is no such episode."
  @spec key(Ecto.UUID.t() | nil) :: String.t() | nil
  def key(nil), do: nil

  def key(id),
    do: id |> Episodes.Episode.Query.by_id() |> Episodes.Episode.Query.select_keys() |> Repo.one()

  @doc "The id of the episode kept under `key`, or nil when there is none: `key/1` read back."
  @spec key_id(String.t() | nil) :: Ecto.UUID.t() | nil
  def key_id(key) when is_binary(key) and byte_size(key) <= 1_024 do
    key |> Episodes.Episode.Query.by_key() |> Episodes.Episode.Query.select_ids() |> Repo.one()
  end

  def key_id(_key), do: nil

  @doc """
  The reference a request's page reads, from the id its address carries
  (`Ryker.ControlPlane.Paths.request/1`): the request's key when a request
  has that id, otherwise the message's (`ingress-input:<id>`) when a message
  does. A request a message started has the message's id, so the message's
  page becomes the request's at the same address.
  """
  @spec request_key(String.t() | nil) :: {:ok, String.t()} | :not_found
  def request_key(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> stored_request_key(id)
      :error -> :not_found
    end
  end

  def request_key(_id), do: :not_found

  defp stored_request_key(id) do
    cond do
      key = key(id) -> {:ok, key}
      Repo.exists?(Ingress.Inbox.Entry.Query.by_id(id)) -> {:ok, "ingress-input:" <> id}
      true -> :not_found
    end
  end

  @doc """
  The topics a request's page listens to, by the id its address carries, as
  the context functions that subscribe to them
  (`Ryker.ControlPlane.WorkbenchLive`): the request, which every context that
  keeps something for it announces, and the conversation it answers, whose
  messages its thread shows. A message no request has taken yet listens to the
  message and its conversation; the message is announced when a request takes
  it, and the page listens to the request from then on. Both show the learning
  passes over their messages, which learning announces on its own topic.
  """
  @spec subscriptions(String.t() | nil) :: [{module(), atom(), list()}]
  def subscriptions(id) do
    case request_key(id) do
      {:ok, key} -> key_subscriptions(key)
      :not_found -> []
    end
  end

  defp key_subscriptions("ingress-input:" <> id), do: input_subscriptions(id)

  defp key_subscriptions(key) do
    found =
      key
      |> Episodes.Episode.Query.by_key()
      |> Episodes.Episode.Query.select_id_destinations()
      |> Repo.one()

    case found do
      {id, transport, conversation_ref} ->
        [{Episodes, :subscribe_conversation, [transport, conversation_ref]}, @learning] ++
          episode_subscriptions(id)

      nil ->
        []
    end
  end

  defp input_subscriptions(id) do
    found =
      id
      |> Ingress.Inbox.Entry.Query.by_id()
      |> Ingress.Inbox.Entry.Query.select_episode_destinations()
      |> Repo.one()

    case found do
      {episode_id, transport, conversation_ref} ->
        [
          {Ingress.Inbox, :subscribe_input, [id]},
          {Episodes, :subscribe_conversation, [transport, conversation_ref]},
          @learning
        ] ++ episode_subscriptions(episode_id)

      nil ->
        [{Ingress.Inbox, :subscribe_input, [id]}, @learning]
    end
  end

  defp episode_subscriptions(nil), do: []
  defp episode_subscriptions(id), do: [{Episodes, :subscribe_episode, [id]}]

  @doc "One episode page: lifecycle metadata, bounded events and records, trace, accounting and links."
  def fetch(ref, params \\ %{})

  def fetch(ref, params) when is_binary(ref) and byte_size(ref) <= 1_024 and is_map(params) do
    ref = ModelRequests.episode_ref(ref)

    case Repo.one(Episodes.Episode.Query.by_key(ref)) do
      nil ->
        :not_found

      episode ->
        event_records =
          episode.id
          |> Episodes.Event.Query.by_episode_id()
          |> Episodes.Event.Query.ordered_by_sequence_desc()
          |> Episodes.Event.Query.limit_to(500)
          |> Repo.all()
          |> Enum.reverse()

        events =
          Enum.map(event_records, fn event ->
            %{
              kind: event.kind,
              occurred_at: event.occurred_at,
              summary: Wording.words(event.kind)
            }
          end)

        record_records =
          episode.id
          |> Records.Record.Query.by_episode_id()
          |> Records.Record.Query.ordered_by_sequence_desc()
          |> Records.Record.Query.limit_to(@record_limit)
          |> Repo.all()
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
          nil
          |> Accounting.Execution.Query.ledger("all")
          |> Accounting.Execution.Query.by_episode_id(episode.id)
          |> UsageProjection.totals()

        {:ok,
         %{
           episode: %{
             created_at: episode.inserted_at,
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
             conversation_link:
               Activity.conversation_link(
                 episode.destination_transport,
                 episode.destination_conversation_ref,
                 episode.execution_mode
               ),
             next_action: trace.next_action,
             ref: episode.key,
             state: episode.state,
             updated_at: episode.updated_at
           },
           events: events,
           records: records,
           related_episodes: related_episodes(episode),
           task: TaskProgress.for_episode(episode),
           accounting: accounting,
           feedback: FeedbackProjection.for_request({:episode, episode.id}),
           self_analysis:
             ImprovementRequests.entries([episode_id: episode.id],
               secrets: Ryker.InspectionRedactor.configured_secrets(),
               disclosed: ModelRequests.disclosed(params)
             ),
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
    related = episode |> EpisodeTrace.Query.related(21) |> Repo.all()

    titles = Activity.request_titles(Enum.map(related, & &1.key))

    %{
      truncated: length(related) > 20,
      items:
        Enum.map(Enum.take(related, 20), fn other ->
          %{
            ref: other.key,
            title: get_in(titles, [other.key, :title]) || "Earlier request",
            href: Paths.request(other.id),
            at: other.inserted_at,
            state: other.state,
            relation:
              if(other.id == episode.linked_episode_id,
                do: "Earlier request",
                else: "Follow-up request"
              )
          }
        end)
    }
  end

  defp record_summary(%Records.Record{subject_ref: subject}) when is_binary(subject), do: subject
  defp record_summary(%Records.Record{operation_id: operation}), do: operation
end
