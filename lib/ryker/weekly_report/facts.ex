defmodule Ryker.WeeklyReport.Facts do
  @moduledoc """
  Everything the weekly report says, read from the database for one week
  (`Ryker.WeeklyReport`), with no model anywhere: the messages Ryker handled
  and how fast it replied, what it finished and what is still open, the pull
  requests it opened and the ones waiting for a review, what is stuck, and a
  line on feedback and what it learned. It counts the week's requests only to
  tell a quiet week; the report states no completion rate.

  A week is `%{from: from, to: to}`. A request counts for the week when
  someone asked something in it or Ryker answered in it, so a request
  started last week and finished this week is this week's work too. Each
  stands as it is now. Only live traffic counts; a shadow deployment's
  replays are not Ryker's week.

  The report is posted into one channel, so it names only what everyone in
  the workspace could read anyway: a request or a topic from a public Slack
  channel Ryker is in (`public?/1`). Anything from a direct message, a
  private channel, a shared channel, Chat or GitHub is counted, never named.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{FailureExplanation, FailureProjection}
  alias Ryker.Episodes.{Episode, Event, RoutingDigests}
  alias Ryker.Feedback.Signal
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Publication.{Followup, Publication}
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelMembership, Names}

  @negative [:frustrated, :asked_again, :edited]
  # A message routing left alone was not handled; a reply or a reaction
  # routing sent itself answered it on the spot.
  @handled [:quick_reply, :react, :reply, :start_episode, :continue_episode]
  @on_the_spot [:quick_reply, :react]
  @named_done 5
  @named_open 3
  @named_pull_requests 5
  @named_stuck 3

  @type week :: %{from: DateTime.t(), to: DateTime.t()}

  @doc "Every fact the report states for `week`, read at `now` (what is stuck then)."
  @spec read(week(), DateTime.t()) :: map()
  def read(%{from: from, to: to} = week, %DateTime{} = now) do
    requests = requests(from, to)
    {done, open} = Enum.split_with(requests, &(&1.standing == :finished))

    %{
      week: week,
      messages: messages(from, to),
      reply_ms: typical_reply_ms(from, to),
      requests: %{total: length(requests), finished: length(done)},
      pull_requests: pull_requests(from, to),
      done: named(done, @named_done),
      open: open |> Enum.reject(&(&1.standing == :stopped)) |> named(@named_open),
      stuck: stuck(now),
      feedback: feedback(from, to),
      learned: learned(from, to)
    }
  end

  @doc """
  Whether `conversation_ref` is a public Slack channel Ryker is in: joined,
  neither private nor shared with another organization. Only what came from
  one is named in a report posted to a channel.
  """
  @spec public?(String.t() | nil) :: boolean()
  def public?("slack:" <> rest) do
    case String.split(rest, ":") do
      [workspace, "C" <> _ = channel] ->
        Repo.exists?(
          from(membership in ChannelMembership,
            where:
              membership.workspace_ref == ^workspace and membership.channel_ref == ^channel and
                membership.status == :joined and membership.private == false and
                membership.external_shared == false
          )
        )

      _direct_or_thread ->
        false
    end
  end

  def public?(_conversation_ref), do: false

  # -- The week's work -----------------------------------------------------------------

  # Each request someone asked something in that week or Ryker answered in,
  # as it stands now, with how much Ryker answered in it that week. A request
  # is stuck while one of its turns waits on Failures.
  defp requests(from, to) do
    {naive_from, naive_to} = {DateTime.to_naive(from), DateTime.to_naive(to)}

    week_events =
      from(event in Event,
        where:
          event.episode_id == parent_as(:episode).id and
            event.kind in [:input_admitted, :result_accepted] and
            event.occurred_at >= ^from and event.occurred_at < ^to
      )

    from(episode in Episode,
      as: :episode,
      where: episode.execution_mode == :live and exists(week_events),
      select: %{
        id: episode.id,
        key: episode.key,
        state: episode.state,
        conversation: episode.destination_conversation_ref,
        stuck:
          fragment(
            "EXISTS (SELECT 1 FROM episode_work_turns AS turn WHERE turn.episode_id = ? AND turn.status = 'blocked')",
            episode.id
          ),
        answers:
          fragment(
            "(SELECT count(*) FROM episode_kernel_events AS event WHERE event.episode_id = ? AND event.kind = 'result_accepted' AND event.occurred_at >= ? AND event.occurred_at < ?)",
            episode.id,
            ^naive_from,
            ^naive_to
          ),
        last_at:
          fragment(
            "(SELECT max(event.occurred_at) FROM episode_kernel_events AS event WHERE event.episode_id = ? AND event.occurred_at < ?)",
            episode.id,
            ^naive_to
          )
      }
    )
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :standing, standing(&1)))
  end

  defp standing(%{state: :complete}), do: :finished
  defp standing(%{state: :cancelled}), do: :stopped
  defp standing(%{state: :waiting_for_input}), do: :waiting
  defp standing(%{stuck: true}), do: :stuck
  defp standing(%{state: :waiting_for_event}), do: :watching
  defp standing(%{state: :working}), do: :going

  # The requests the report may name, the ones with a draft PR first, then
  # the ones Ryker answered most in, then the newest, one line per title in a
  # channel; how many there are, and how many are in private conversations.
  defp named(requests, limit) do
    titles = requests |> Enum.map(& &1.id) |> RoutingDigests.titles()
    pull_requests = requests |> Enum.map(& &1.id) |> newest_pull_requests()
    public = requests |> Enum.map(& &1.conversation) |> Enum.uniq() |> Enum.filter(&public?/1)

    shown =
      requests
      |> Enum.filter(&(&1.conversation in public and is_binary(titles[&1.id])))
      |> Enum.map(fn request ->
        %{
          title: titles[request.id],
          where: Names.destination(request.conversation),
          href: "/timeline/" <> URI.encode_www_form(request.key),
          standing: request.standing,
          pull_request: pull_requests[request.id],
          rank:
            {if(pull_requests[request.id], do: 1, else: 0), request.answers,
             unix(request.last_at), request.key}
        }
      end)
      |> Enum.sort_by(& &1.rank, :desc)
      |> Enum.uniq_by(&{&1.title, &1.where})
      |> Enum.take(limit)
      |> Enum.map(&Map.delete(&1, :rank))

    %{
      named: shown,
      total: length(requests),
      private: Enum.count(requests, &(&1.conversation not in public))
    }
  end

  defp unix(nil), do: 0

  defp unix(%NaiveDateTime{} = at),
    do: NaiveDateTime.diff(at, ~N[1970-01-01 00:00:00], :microsecond)

  # Each request's newest pull request, as its task card links it.
  defp newest_pull_requests([]), do: %{}

  defp newest_pull_requests(episode_ids) do
    from(publication in Publication,
      where:
        publication.episode_id in ^episode_ids and not is_nil(publication.pull_request_url) and
          not is_nil(publication.pull_request_number),
      order_by: [asc: publication.inserted_at, asc: publication.id],
      select:
        {publication.episode_id,
         %{number: publication.pull_request_number, url: publication.pull_request_url}}
    )
    |> Repo.all()
    |> Map.new()
  end

  # The messages that reached Ryker that week and got an answer, and how many
  # of them routing answered on the spot: a reply or a reaction without a
  # request behind it. The rest started or joined a request.
  defp messages(from, to) do
    counts =
      from(entry in Entry,
        where:
          entry.execution_mode == :live and entry.decision_action in ^@handled and
            entry.inserted_at >= ^from and entry.inserted_at < ^to,
        group_by: entry.decision_action,
        select: {entry.decision_action, count()}
      )
      |> Repo.all()
      |> Map.new()

    %{
      handled: counts |> Map.values() |> Enum.sum(),
      on_the_spot: @on_the_spot |> Enum.map(&Map.get(counts, &1, 0)) |> Enum.sum()
    }
  end

  # How long a typical reply took that week, in milliseconds: the middle
  # one of each message's wait, from when it was sent to the first answer
  # that reached its conversation, routing's own or its request's, as a
  # request's page measures it (`Ryker.ControlPlane.EpisodeResponseMetrics`).
  # The middle one, not the average: in the week to 30 Sep the live install's
  # quick replies averaged half an hour because one was delivered 28 hours
  # late, while the middle one took 15 seconds. Nil when nothing was answered.
  defp typical_reply_ms(from, to) do
    %{rows: [[seconds]]} =
      Repo.query!(
        """
        WITH waits AS (
          SELECT extract(epoch FROM min(response.delivered_at) - entry.occurred_at)::float8 AS seconds
          FROM ingress_inbox_entries AS entry
          JOIN delivery_routing_responses AS response
            ON response.input_id = entry.id AND response.status = 'delivered'
          WHERE entry.execution_mode = 'live' AND entry.decision_action IN ('quick_reply', 'react')
            AND entry.inserted_at >= $1 AND entry.inserted_at < $2
          GROUP BY entry.id, entry.occurred_at
          UNION ALL
          SELECT extract(epoch FROM min(turn.delivered_at) - event.occurred_at)::float8
          FROM episode_kernel_events AS event
          JOIN episode_kernel_episodes AS episode
            ON episode.id = event.episode_id AND episode.execution_mode = 'live'
          JOIN episode_work_turns AS turn
            ON turn.episode_id = event.episode_id AND turn.delivered_at IS NOT NULL
              AND event.dedupe_key = ANY(turn.selected_input_refs)
          WHERE event.kind = 'input_admitted' AND event.occurred_at >= $1 AND event.occurred_at < $2
          GROUP BY event.id, event.occurred_at
        )
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY seconds) FROM waits WHERE seconds >= 0
        """,
        [DateTime.to_naive(from), DateTime.to_naive(to)]
      )

    seconds && round(seconds * 1000)
  end

  # The pull requests Ryker opened that week and how many of them are merged
  # by now, and every pull request of its still open, newest first: the ones
  # waiting for someone to review them. A pull request is opened when its
  # publication first goes out, which is when its follow-up starts; a
  # follow-up rearmed later keeps that time.
  defp pull_requests(from, to) do
    opened =
      from(followup in Followup,
        join: episode in Episode,
        on: episode.id == followup.episode_id and episode.execution_mode == :live,
        where: followup.inserted_at >= ^from and followup.inserted_at < ^to,
        select: followup.pr_state
      )
      |> Repo.all()

    waiting =
      from(followup in Followup,
        join: publication in Publication,
        on: publication.id == followup.publication_id,
        join: episode in Episode,
        on: episode.id == followup.episode_id and episode.execution_mode == :live,
        where:
          followup.pr_state in ["open", "stale"] and not is_nil(publication.pull_request_url) and
            not is_nil(publication.pull_request_number),
        order_by: [desc: followup.inserted_at, desc: followup.id],
        select: %{
          number: publication.pull_request_number,
          url: publication.pull_request_url,
          title: publication.title,
          conversation: episode.destination_conversation_ref
        }
      )
      |> Repo.all()

    public = waiting |> Enum.map(& &1.conversation) |> Enum.uniq() |> Enum.filter(&public?/1)

    %{
      opened: length(opened),
      merged: Enum.count(opened, &(&1 == "merged")),
      waiting: %{
        named:
          waiting
          |> Enum.filter(&(&1.conversation in public and is_binary(&1.title)))
          |> Enum.take(@named_pull_requests)
          |> Enum.map(fn pull_request ->
            pull_request
            |> Map.take([:number, :url, :title])
            |> Map.put(:where, Names.destination(pull_request.conversation))
          end),
        total: length(waiting)
      }
    }
  end

  # -- Stuck ---------------------------------------------------------------------------

  # The failures open now that leave someone without a reply, an update or a
  # result, newest first, as the Failures page lists and explains them. A read
  # that failed is not "nothing is stuck".
  defp stuck(now) do
    case FailureProjection.list(%{}) do
      {:ok, rows} ->
        people =
          rows
          |> Enum.map(&{&1, FailureExplanation.explain(&1, now)})
          |> Enum.filter(fn {_row, explanation} -> explanation.impact == :people end)

        %{
          total: length(people),
          partial: length(rows) == FailureProjection.page_size(),
          named:
            people
            |> Enum.take(@named_stuck)
            |> Enum.map(fn {row, explanation} ->
              %{title: explanation.title, href: FailureExplanation.path(row)}
            end)
        }

      {:error, :unavailable} ->
        :unavailable
    end
  end

  # -- Feedback and what Ryker learned -------------------------------------------------

  defp feedback(from, to) do
    counts =
      from(signal in Signal,
        where: signal.occurred_at >= ^from and signal.occurred_at < ^to,
        group_by: signal.category,
        select: {signal.category, count()}
      )
      |> Repo.all()
      |> Map.new()

    %{
      positive: Map.get(counts, :satisfied, 0),
      negative: @negative |> Enum.map(&Map.get(counts, &1, 0)) |> Enum.sum()
    }
  end

  # The facts people confirmed and the topics Ryker learned that week, and
  # the newest topic from a public channel, the one the report may name.
  defp learned(from, to) do
    facts =
      Repo.aggregate(
        from(fact in MemoryEntry,
          where: fact.status == :active and fact.confirmed_at >= ^from and fact.confirmed_at < ^to
        ),
        :count
      )

    topics =
      from(topic in ConversationKnowledge,
        where:
          is_nil(topic.forgotten_at) and topic.inserted_at >= ^from and topic.inserted_at < ^to,
        order_by: [desc: topic.inserted_at, desc: topic.id],
        select: %{conversation: topic.conversation_ref, state: topic.state}
      )
      |> Repo.all()

    %{
      count: facts + length(topics),
      newest:
        topics
        |> Enum.filter(&public?(&1.conversation))
        |> Enum.find_value(&topic_title/1)
    }
  end

  # A topic whose words expired has no title left to name.
  defp topic_title(%{state: %{"retention" => "pruned"}}), do: nil
  defp topic_title(%{state: %{"title" => title}}) when is_binary(title), do: redacted(title)
  defp topic_title(_topic), do: nil

  defp redacted(text) do
    artifact = InspectionRedactor.artifact(text, max_bytes: 8_192)

    case artifact.text && String.trim(artifact.text) do
      "" -> nil
      text -> text
    end
  end
end
