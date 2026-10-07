defmodule Ryker.Slack.AppHomeProjection do
  @moduledoc """
  Bounded read model for Slack App Home.

  The projection never grants authority. It exposes only lifecycle identity,
  bounded request text from the exact Slack workspace, short operator-authored
  titles, counts, and the next host-owned action.
  """

  alias Ryker.Episodes.Episode
  alias Ryker.Memories
  alias Ryker.Publication.{Publication, Review}
  alias Ryker.Repo
  alias Ryker.Schedules.Schedule
  alias Ryker.Slack.{AppHomeQuery, Collections, SavedEntity}
  alias Ryker.Work.Session

  @maximum_collection_rows 10
  @maximum_attention 8
  @maximum_work 8
  @maximum_incidents 5
  @maximum_behaviors 5
  @maximum_memories 5
  @maximum_memory_reviews 2
  @maximum_schedules 5
  @maximum_title 240
  @publication_conflicts ~w(publication_branch_already_exists publication_branch_changed publication_existing_pull_request_changed publication_pull_request_mismatch)

  @spec snapshot(String.t(), String.t(), MapSet.t(String.t())) :: map()
  def snapshot(workspace_ref, actor_ref, %MapSet{} = shared_conversations) do
    if workspace_ref?(workspace_ref) and actor_ref?(actor_ref) and
         shared_conversations?(shared_conversations) do
      now = Repo.now!()

      destination_refs =
        shared_conversations
        |> Enum.map(&"slack:#{workspace_ref}:#{&1}")
        |> Enum.sort()

      channel_refs = shared_conversations |> MapSet.to_list() |> Enum.sort()

      actor_scope = "slack:user:#{actor_ref}"
      workspace_scope = "slack:#{workspace_ref}"

      memory_reviews =
        Memories.home_reviews(workspace_scope, actor_scope, limit: @maximum_memory_reviews)

      memory_reviews = %{
        memory_reviews
        | items:
            Enum.map(
              memory_reviews.items,
              &decorate_memory_review(&1, workspace_ref, shared_conversations)
            )
      }

      %{
        behaviors:
          behaviors(
            workspace_scope,
            "slack:user:#{actor_ref}",
            workspace_ref,
            shared_conversations,
            now
          ),
        counts: counts(workspace_ref, actor_scope, destination_refs, channel_refs, now),
        incidents: incidents(workspace_ref, channel_refs),
        memories: memories("slack:#{workspace_ref}", workspace_ref, shared_conversations, now),
        memory_review_count: memory_reviews.total,
        memory_reviews: memory_reviews.items,
        needs_attention: needs_attention(workspace_ref, destination_refs, channel_refs),
        schedules: schedules(workspace_ref, destination_refs, now),
        work: work(workspace_ref, destination_refs)
      }
    else
      unreadable()
    end
  end

  def snapshot(_workspace_ref, _actor_ref, _shared_conversations), do: unreadable()

  @spec empty() :: map()
  def empty do
    %{
      counts: %{
        active_behaviors: 0,
        active_commitments: 0,
        active_memory: 0,
        active_schedules: 0,
        blocked_work: 0,
        incident_history: 0,
        open_incidents: 0,
        published_work: 0,
        retained_workspaces: 0
      },
      behaviors: [],
      incidents: [],
      memories: [],
      memory_review_count: 0,
      memory_reviews: [],
      needs_attention: [],
      readable: true,
      schedules: [],
      work: []
    }
  end

  @doc """
  The dashboard for a reader whose identity this projection cannot resolve.

  Returning `empty/0` here said the person has nothing, which is a different
  claim from not being able to tell. The collection views already keep those
  apart; the dashboard read them the same until 2026-09-12.
  """
  @spec unreadable() :: map()
  def unreadable, do: %{empty() | readable: false}

  @doc """
  One bounded page of a requested collection across the channels the reader
  shares with Ryker.

  The dashboard sections are a capped digest; this is the complete authorized
  list the collections card points at, read from the same scoped query the
  channel's own page is cut from. A page that could not be read is
  `:unavailable`, never an empty list.
  """
  @spec collection(Collections.kind(), String.t(), MapSet.t(String.t()), non_neg_integer()) ::
          map()
  def collection(kind, workspace_ref, shared_conversations, offset) do
    with true <- kind in Collections.kinds(),
         true <- workspace_ref?(workspace_ref),
         %MapSet{} <- shared_conversations,
         true <- shared_conversations?(shared_conversations),
         true <- is_integer(offset) and offset >= 0,
         {:ok, page} <-
           Collections.page(
             kind,
             %{
               channel_refs: shared_conversations |> MapSet.to_list() |> Enum.sort(),
               workspace_ref: workspace_ref
             },
             offset,
             @maximum_collection_rows
           ) do
      %{
        kind: kind,
        offset: page.offset,
        outcome: if(page.total == 0, do: :empty, else: :listed),
        page_size: @maximum_collection_rows,
        rows: Enum.map(page.entries, &collection_row(&1, workspace_ref, shared_conversations)),
        total: page.total
      }
    else
      _unreadable ->
        %{
          kind: kind,
          offset: 0,
          outcome: :unavailable,
          page_size: @maximum_collection_rows,
          rows: [],
          total: 0
        }
    end
  end

  defp collection_row(entity, workspace_ref, shared_conversations) do
    document = SavedEntity.document(entity)

    %{
      detail: document["notice"],
      ref: document["ref"],
      title: document["title"],
      url: collection_url(entity, workspace_ref, shared_conversations)
    }
  end

  defp collection_url(%Schedule{} = schedule, workspace_ref, _shared_conversations) do
    slack_url(
      workspace_ref,
      schedule.destination_conversation_ref,
      schedule.destination_thread_ref
    )
  end

  defp collection_url(entity, workspace_ref, shared_conversations),
    do: source_url(entity, workspace_ref, shared_conversations)

  defp counts(workspace_ref, actor_ref, destination_refs, channel_refs, now) do
    %{
      active_behaviors: active_behavior_count("slack:#{workspace_ref}", actor_ref, now),
      active_commitments: active_commitment_count(destination_refs),
      active_memory: active_memory_count("slack:#{workspace_ref}", now),
      active_schedules: active_schedule_count(destination_refs, now),
      blocked_work: blocked_work_count(destination_refs),
      incident_history: incident_count(workspace_ref, channel_refs, :closed),
      open_incidents: incident_count(workspace_ref, channel_refs, :open),
      published_work: published_work_count(destination_refs),
      retained_workspaces: retained_workspace_count(destination_refs)
    }
  end

  defp needs_attention(workspace_ref, destination_refs, channel_refs) do
    (operator_waits(workspace_ref, destination_refs) ++
       blocked_work(workspace_ref, destination_refs) ++
       publication_attention(workspace_ref, destination_refs) ++
       retained_workspace_attention(workspace_ref, destination_refs) ++
       incident_attention(workspace_ref, channel_refs))
    |> Enum.sort_by(&{DateTime.to_unix(&1.updated_at, :microsecond), &1.ref}, :desc)
    |> Enum.take(@maximum_attention)
    |> Enum.map(&Map.delete(&1, :updated_at))
  end

  defp active_behavior_count(workspace_ref, actor_ref, now),
    do: count(AppHomeQuery.active_behaviors(workspace_ref, actor_ref, now))

  defp active_commitment_count(destination_refs),
    do: count(AppHomeQuery.active_commitments(destination_refs))

  defp active_memory_count(workspace_ref, now),
    do: count(AppHomeQuery.workspace_facts(workspace_ref, now))

  defp active_schedule_count(destination_refs, now),
    do: count(AppHomeQuery.active_schedules(destination_refs, now))

  defp blocked_work_count(destination_refs),
    do: count(AppHomeQuery.blocked_turns(destination_refs))

  defp incident_count(workspace_ref, channel_refs, state),
    do: count(AppHomeQuery.incidents(workspace_ref, channel_refs, state))

  defp published_work_count(destination_refs),
    do: count(AppHomeQuery.published_work(destination_refs))

  defp retained_workspace_count(destination_refs),
    do: count(AppHomeQuery.retained_workspaces(destination_refs))

  defp operator_waits(workspace_ref, destination_refs) do
    destination_refs
    |> AppHomeQuery.operator_waits(@maximum_attention)
    |> Repo.all()
    |> with_requests()
    |> Enum.map(fn {episode, title} ->
      episode_attention(episode, title, workspace_ref, :operator_input, [])
    end)
  end

  defp blocked_work(workspace_ref, destination_refs) do
    destination_refs
    |> AppHomeQuery.listed_blocked_turns(@maximum_attention)
    |> Repo.all()
    |> with_requests(&elem(&1, 0))
    |> Enum.map(fn {{episode, updated_at}, title} ->
      episode
      |> episode_attention(title, workspace_ref, :blocked_work, [])
      |> Map.put(:updated_at, updated_at)
    end)
  end

  defp publication_attention(workspace_ref, destination_refs) do
    destination_refs
    |> AppHomeQuery.publication_attention(@publication_conflicts, @maximum_attention)
    |> Repo.all()
    |> Enum.map(fn publication ->
      controls = publication_controls(publication)

      %{
        controls: controls,
        kind: publication.status,
        recovery_generation: publication.recovery_generation,
        ref: publication.ref,
        title: publication.title,
        updated_at: publication.updated_at,
        url:
          slack_url(
            workspace_ref,
            publication.destination_conversation_ref,
            publication.destination_thread_ref
          )
      }
    end)
    |> Enum.reject(&(&1.controls == []))
  end

  defp incident_attention(workspace_ref, channel_refs) do
    workspace_ref
    |> AppHomeQuery.blocked_incidents(channel_refs, @maximum_attention)
    |> Repo.all()
    |> Enum.map(fn room ->
      %{
        controls: [],
        kind: :blocked_incident,
        ref: room.ref,
        title: room.title,
        updated_at: room.updated_at,
        url: slack_url(workspace_ref, room.channel_ref, nil)
      }
    end)
  end

  defp retained_workspace_attention(workspace_ref, destination_refs) do
    destination_refs
    |> AppHomeQuery.unmerged_workspaces(@maximum_attention)
    |> Repo.all()
    |> Enum.filter(fn {session, _episode} -> safe_unmerged_discard?(session) end)
    |> with_requests(&elem(&1, 1))
    |> Enum.map(fn {{session, episode}, request} ->
      %{
        controls: ["discard_workspace"],
        discard_plan_fingerprint: session.discard_plan_fingerprint,
        kind: :retained_workspace,
        ref: session.external_ref,
        title: workspace_request(session, request),
        updated_at: session.updated_at,
        url:
          slack_url(
            workspace_ref,
            episode.destination_conversation_ref,
            episode.destination_thread_ref
          )
      }
    end)
  end

  defp work(workspace_ref, destination_refs) do
    destination_refs
    |> AppHomeQuery.work(@maximum_work)
    |> Repo.all()
    |> with_requests(&elem(&1, 0))
    |> Enum.map(fn {{episode, turn_status, coop_turn_id}, title} ->
      %{
        next_action: next_action(episode, turn_status, coop_turn_id),
        ref: episode.key,
        state: episode.state,
        title: title,
        url:
          slack_url(
            workspace_ref,
            episode.destination_conversation_ref,
            episode.destination_thread_ref
          )
      }
    end)
  end

  defp incidents(workspace_ref, channel_refs) do
    workspace_ref
    |> AppHomeQuery.listed_open_incidents(channel_refs, @maximum_incidents)
    |> Repo.all()
    |> Enum.map(fn room ->
      %{
        channel_ref: room.channel_ref,
        ref: room.ref,
        status: room.status,
        title: room.title,
        url: slack_url(workspace_ref, room.channel_ref, nil)
      }
    end)
  end

  defp behaviors(workspace_ref, actor_ref, slack_workspace_ref, shared_conversations, now) do
    workspace_ref
    |> AppHomeQuery.listed_behaviors(actor_ref, now, @maximum_behaviors)
    |> Repo.all()
    |> Enum.map(fn behavior ->
      %{
        kind: behavior.kind,
        ref: behavior.ref,
        revision: behavior.revision,
        status: behavior.status,
        subject: behavior.identity_key,
        url: source_url(behavior, slack_workspace_ref, shared_conversations)
      }
    end)
  end

  defp memories(workspace_ref, slack_workspace_ref, shared_conversations, now) do
    workspace_ref
    |> AppHomeQuery.listed_facts(now, @maximum_memories)
    |> Repo.all()
    |> Enum.map(fn memory ->
      %{
        kind: memory.kind,
        ref: memory.ref,
        subject: memory.subject,
        url: source_url(memory, slack_workspace_ref, shared_conversations)
      }
    end)
  end

  defp decorate_memory_review(%{"entries" => entries} = review, workspace_ref, conversations)
       when is_list(entries) do
    entries =
      Enum.map(entries, fn entry ->
        case source_url(entry, workspace_ref, conversations) do
          nil -> entry
          url -> Map.put(entry, "url", url)
        end
      end)

    Map.put(review, "entries", entries)
  end

  defp decorate_memory_review(review, _workspace_ref, _conversations), do: review

  defp schedules(workspace_ref, destination_refs, now) do
    destination_refs
    |> AppHomeQuery.listed_schedules(now, @maximum_schedules)
    |> Repo.all()
    |> Enum.map(fn schedule ->
      %{
        next_occurrence_at: schedule.next_occurrence_at,
        ref: schedule.ref,
        revision: schedule.revision,
        status: schedule.status,
        title: schedule.title,
        url:
          slack_url(
            workspace_ref,
            schedule.destination_conversation_ref,
            schedule.destination_thread_ref
          )
      }
    end)
  end

  defp episode_attention(episode, title, workspace_ref, kind, controls) do
    %{
      controls: controls,
      kind: kind,
      ref: episode.key,
      title: title,
      updated_at: episode.updated_at,
      url:
        slack_url(
          workspace_ref,
          episode.destination_conversation_ref,
          episode.destination_thread_ref
        )
    }
  end

  # Each row with what its work was asked: the latest session's task, else the
  # first message. Read for every row at once; two queries a row ran inside
  # the gateway every Slack event waits on (2026-10-04 review).
  defp with_requests(rows, episode_of \\ & &1)
  defp with_requests([], _episode_of), do: []

  defp with_requests(rows, episode_of) do
    ids = rows |> Enum.map(&episode_of.(&1).id) |> Enum.uniq()

    tasks = ids |> AppHomeQuery.latest_tasks() |> Repo.all() |> Map.new()
    inputs = ids |> AppHomeQuery.first_inputs() |> Repo.all() |> Map.new()

    Enum.map(rows, fn row ->
      episode = episode_of.(row)
      input = request_from_payload(inputs[episode.id])
      {row, episode_request(tasks[episode.id], input, episode)}
    end)
  end

  defp episode_request(task, input, episode) when is_map(task),
    do: first_text([task["prompt"], task["title"], input, episode.key])

  defp episode_request(_task, input, episode), do: first_text([input, episode.key])

  defp workspace_request(%Session{workspace_task: task}, request) when is_map(task),
    do: first_text([task["prompt"], task["title"], request])

  defp workspace_request(_session, request), do: request

  defp request_from_payload(payload) when is_map(payload) do
    input = payload["payload"] || %{}
    content = input["content"] || %{}
    task = payload["task"] || %{}
    schedule = content["schedule"] || %{}

    first_text([
      content["text"],
      input["text"],
      task["prompt"],
      task["title"],
      schedule["title"],
      content["title"]
    ])
  end

  defp request_from_payload(_payload), do: nil

  defp first_text(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value =
          value
          |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u, " ")
          |> String.trim()
          |> String.slice(0, @maximum_title)

        if value == "", do: nil, else: value

      _invalid ->
        nil
    end)
  end

  defp publication_controls(%Publication{
         status: status,
         last_error_code: code,
         expected_remote_head_sha: head_sha
       })
       when status == :publish_pending and code in @publication_conflicts and
              is_binary(head_sha),
       do: ["update", "discard"]

  defp publication_controls(%Publication{status: :publish_pending, last_error_code: code})
       when code in @publication_conflicts,
       do: ["discard"]

  defp publication_controls(%Publication{status: status, last_error_code: code})
       when status in [:review_pending, :review_ready, :publish_pending, :published_ready] and
              is_binary(code),
       do: ["retry"]

  # As on the task card: a change in a repository with no checks gets the same
  # answer from every review, so it is not offered one.
  defp publication_controls(%Publication{status: :blocked, approval_ref: nil} = publication) do
    if Review.draft_shareable?(publication.review_document) and
         Review.no_checks?(publication.review_document),
       do: ["discard"],
       else: ["update", "discard"]
  end

  defp publication_controls(%Publication{status: :reviewed, approval_ref: nil}),
    do: ["update", "discard"]

  defp publication_controls(%Publication{status: :published, expected_remote_head_sha: head_sha})
       when is_binary(head_sha),
       do: ["update", "discard"]

  defp publication_controls(_publication), do: []

  defp safe_unmerged_discard?(%Session{
         discard_plan: %{"workspace" => %{"dirty" => false, "unmerged" => true}},
         discard_plan_fingerprint: fingerprint,
         external_ref: external_ref
       }),
       do: is_binary(fingerprint) and is_binary(external_ref)

  defp safe_unmerged_discard?(_session), do: false

  defp slack_url(workspace_ref, "slack:" <> _ = conversation_ref, thread_ref) do
    case String.split(conversation_ref, ":", parts: 3) do
      ["slack", ^workspace_ref, channel_ref] -> slack_url(workspace_ref, channel_ref, thread_ref)
      _invalid -> nil
    end
  end

  defp slack_url(workspace_ref, channel_ref, thread_ref)
       when is_binary(workspace_ref) and is_binary(channel_ref) do
    if Regex.match?(~r/\A[A-Z0-9]+\z/, workspace_ref) and
         Regex.match?(~r/\A[A-Z0-9]+\z/, channel_ref) do
      parameters = [team: workspace_ref, channel: channel_ref]

      parameters =
        if is_binary(thread_ref) and Regex.match?(~r/\A[0-9]{10,}\.[0-9]{1,6}\z/, thread_ref),
          do: parameters ++ [message_ts: thread_ref],
          else: parameters

      "https://slack.com/app_redirect?" <> URI.encode_query(parameters)
    end
  end

  defp slack_url(_workspace_ref, _channel_ref, _thread_ref), do: nil

  defp source_url(resource, workspace_ref, conversations) when is_map(resource) do
    transport = Map.get(resource, :source_transport, Map.get(resource, "source_transport"))

    conversation_ref =
      Map.get(resource, :source_conversation_ref, Map.get(resource, "source_conversation_ref"))

    thread_ref = Map.get(resource, :source_thread_ref, Map.get(resource, "source_thread_ref"))

    if transport == "slack" and
         conversation_visible?(conversation_ref, workspace_ref, conversations),
       do: slack_url(workspace_ref, conversation_ref, thread_ref),
       else: nil
  end

  defp conversation_visible?(conversation_ref, workspace_ref, conversations) do
    case String.split(to_string(conversation_ref), ":", parts: 3) do
      ["slack", ^workspace_ref, channel_ref] -> MapSet.member?(conversations, channel_ref)
      _invalid -> false
    end
  end

  defp next_action(%Episode{state: :waiting_for_input}, _turn_status, _coop_turn_id),
    do: "operator_input"

  defp next_action(%Episode{state: :waiting_for_event}, _turn_status, _coop_turn_id),
    do: "external_event"

  defp next_action(%Episode{owner_kind: :delivery}, _turn_status, _coop_turn_id),
    do: "deliver_result"

  defp next_action(_episode, :blocked, _coop_turn_id), do: "operator_recovery"
  defp next_action(_episode, :cancel_pending, _coop_turn_id), do: "reconcile_stop"
  defp next_action(_episode, _turn_status, nil), do: "start_work"
  defp next_action(_episode, _turn_status, _coop_turn_id), do: "continue_work"

  defp count(query), do: Repo.aggregate(query, :count, :id)

  defp workspace_ref?(value) do
    is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value) and byte_size(value) <= 256
  end

  defp actor_ref?(value) do
    is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value) and byte_size(value) <= 256
  end

  defp shared_conversations?(conversations) do
    MapSet.size(conversations) <= 20_000 and Enum.all?(conversations, &channel_ref?/1)
  end

  defp channel_ref?(value) do
    is_binary(value) and Regex.match?(~r/\A[A-Z0-9]+\z/, value) and byte_size(value) <= 256
  end
end
