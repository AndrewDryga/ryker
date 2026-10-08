defmodule Ryker.WeeklyReport.Facts do
  @moduledoc """
  Everything the weekly report says, read from the database for one week
  (`Ryker.WeeklyReport`), with no model anywhere: the pull requests Ryker
  opened, the ones merged and the ones waiting for a review, the messages it
  handled and how fast it replied, what the week's work cost, the questions
  it is waiting on people to answer, what is stuck, and a line on feedback
  and what it learned. It
  counts the week's requests only to tell a quiet week, and names none it
  merely answered: the report states no completion rate and lists no Slack
  requests.

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
  alias Ryker.Accounting
  alias Ryker.ControlPlane
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.Feedback
  alias Ryker.Ingress
  alias Ryker.InspectionRedactor
  alias Ryker.Knowledge
  alias Ryker.Memories
  alias Ryker.Publication
  alias Ryker.Repo
  alias Ryker.Slack

  @negative [:frustrated, :asked_again, :edited]
  # A message routing left alone was not handled; a reply or a reaction
  # routing sent itself answered it on the spot.
  @handled [:quick_reply, :react, :reply, :start_episode, :continue_episode]
  @on_the_spot [:quick_reply, :react]
  @named_pull_requests 5
  @named_questions 5

  @type week :: %{from: DateTime.t(), to: DateTime.t()}

  @doc "Every fact the report states for `week`, read at `now` (what is stuck then)."
  @spec read(week(), DateTime.t()) :: map()
  def read(%{from: from, to: to} = week, %DateTime{} = now) do
    requests = requests(from, to)

    %{
      week: week,
      messages: messages(from, to),
      reply_ms: typical_reply_ms(from, to),
      cost: cost(from, to),
      requests: %{total: length(requests)},
      pull_requests: pull_requests(from, to),
      questions: requests |> Enum.filter(&(&1.standing == :waiting)) |> named(@named_questions),
      stuck: stuck(now),
      feedback: feedback(from, to),
      learned: learned(from, to)
    }
  end

  # Whether `conversation_ref` is a public Slack channel Ryker is in: joined,
  # neither private nor shared with another organization. Only what came from
  # one is named in a report posted to a channel.
  @spec public?(String.t() | nil) :: boolean()
  defp public?("slack:" <> _rest = conversation_ref) do
    case ConversationRef.parse_slack(conversation_ref) do
      {:ok, workspace, "C" <> _ = channel} ->
        workspace
        |> Slack.ChannelMembership.Query.by_channel(channel)
        |> Slack.ChannelMembership.Query.joined_public()
        |> Repo.exists?()

      _direct_or_thread ->
        false
    end
  end

  defp public?(_conversation_ref), do: false

  # -- The week's work -----------------------------------------------------------------

  # Each request someone asked something in that week or Ryker answered in,
  # as it stands now, with how much Ryker answered in it that week. A request
  # is stuck while one of its turns waits on Failures.
  defp requests(from, to) do
    from
    |> Episodes.Episode.Query.asked_or_answered_between(to)
    |> Repo.all()
    |> Enum.map(&Map.put(&1, :standing, standing(&1)))
  end

  defp standing(%{state: :complete}), do: :finished
  defp standing(%{state: :cancelled}), do: :stopped
  defp standing(%{state: :waiting_for_input}), do: :waiting
  defp standing(%{stuck: true}), do: :stuck
  defp standing(%{state: :waiting_for_event}), do: :watching
  defp standing(%{state: :working}), do: :going

  # The requests the report may name, newest first, one line per title in a
  # channel; how many there are, and how many are in private conversations.
  defp named(requests, limit) do
    titles = requests |> Enum.map(& &1.id) |> Episodes.RoutingDigests.titles()
    public = requests |> Enum.map(& &1.conversation) |> Enum.uniq() |> Enum.filter(&public?/1)

    shown =
      requests
      |> Enum.filter(&(&1.conversation in public and is_binary(titles[&1.id])))
      |> Enum.map(fn request ->
        %{
          title: titles[request.id],
          where: Slack.Names.destination(request.conversation),
          href: ControlPlane.Paths.request(request.id),
          rank: {unix(request.last_at), request.key}
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

  # The messages that reached Ryker that week and got an answer, and how many
  # of them routing answered on the spot: a reply or a reaction without a
  # request behind it. The rest started or joined a request.
  defp messages(from, to) do
    counts =
      from
      |> Ingress.Inbox.Entry.Query.decision_counts_between(to, @handled)
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

  # What the week's model calls cost, as the Usage page adds it up
  # (`Ryker.Accounting.Execution.Query`): what the provider reported, plus Ryker's
  # estimate at the saved API prices for calls it reported no price for, as
  # a ChatGPT sign-in never does. Nil when calls ran but none could be
  # priced; `estimated` when any of it is an estimate.
  defp cost(from, to) do
    row =
      from
      |> Accounting.Execution.Query.ledger("live")
      |> Accounting.Execution.Query.recorded_before(to)
      |> Accounting.Execution.Query.select_cost_totals()
      |> Repo.one!()

    %{
      calls: row.calls,
      usd: if(row.priced + row.estimates > 0, do: Decimal.add(row.reported, row.estimated)),
      estimated: row.estimates > 0
    }
  end

  # The pull requests Ryker opened that week and the ones among them merged
  # by now, newest merge first, and every pull request of its still open,
  # newest first: the ones waiting for someone to review them, whenever they
  # were opened. A pull request is opened when its publication first goes
  # out, which is when its follow-up starts; a follow-up rearmed later keeps
  # that time.
  defp pull_requests(from, to) do
    rows = from |> Publication.Followup.Query.pull_requests(to) |> Repo.all()

    this_week = Enum.filter(rows, &within?(&1.opened_at, from, to))

    merged =
      this_week
      |> Enum.filter(&(&1.state == :merged))
      |> Enum.sort_by(&(&1.merged_at || &1.opened_at), {:desc, DateTime})

    waiting = Enum.filter(rows, &(&1.state in [:open, :stale]))
    public = rows |> Enum.map(& &1.conversation) |> Enum.uniq() |> Enum.filter(&public?/1)

    %{
      opened: length(this_week),
      merged: %{named: pull_request_names(merged, public), total: length(merged)},
      waiting: %{
        named: pull_request_names(waiting, public),
        total: length(waiting),
        this_week: Enum.count(waiting, &within?(&1.opened_at, from, to))
      }
    }
  end

  defp within?(at, from, to),
    do: DateTime.compare(at, from) != :lt and DateTime.compare(at, to) == :lt

  # The pull requests the report may name: from a public channel, with a
  # title and a link, and the repository by its own name.
  defp pull_request_names(rows, public) do
    rows
    |> Enum.filter(
      &(&1.conversation in public and is_binary(&1.title) and is_binary(&1.url) and
          is_integer(&1.number))
    )
    |> Enum.take(@named_pull_requests)
    |> Enum.map(fn row ->
      %{
        number: row.number,
        url: row.url,
        title: row.title,
        repository: row.repository && row.repository |> String.split("/") |> List.last(),
        opened_at: row.opened_at
      }
    end)
  end

  # -- Stuck ---------------------------------------------------------------------------

  # The failures open now that leave someone without a reply, an update or a
  # result, newest first, as the Failures page lists and explains them. A read
  # that failed is not "nothing is stuck".
  defp stuck(now) do
    case ControlPlane.FailureProjection.list(%{}) do
      {:ok, rows} ->
        people =
          rows
          |> Enum.map(&{&1, ControlPlane.FailureExplanation.explain(&1, now)})
          |> Enum.filter(fn {_row, explanation} -> explanation.impact == :people end)

        %{
          total: length(people),
          partial: length(rows) == ControlPlane.FailureProjection.page_size()
        }

      {:error, :unavailable} ->
        :unavailable
    end
  end

  # -- Feedback and what Ryker learned -------------------------------------------------

  defp feedback(from, to) do
    counts =
      from
      |> Feedback.Signal.Query.occurred_between(to)
      |> Feedback.Signal.Query.count_by_category()
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
      Memories.MemoryEntry.Query.active()
      |> Memories.MemoryEntry.Query.confirmed_between(from, to)
      |> Repo.aggregate(:count)

    topics = from |> Knowledge.ConversationKnowledge.Query.learned_between(to) |> Repo.all()

    %{
      count: facts + length(topics),
      newest:
        topics
        |> Enum.filter(&public?(&1.conversation_ref))
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
