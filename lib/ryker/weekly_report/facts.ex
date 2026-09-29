defmodule Ryker.WeeklyReport.Facts do
  @moduledoc """
  Everything the weekly report says, read from the database for one week
  (`Ryker.WeeklyReport`), with no model anywhere: the work Ryker did, what
  it finished and what is still open, what is stuck, and a line on feedback
  and what it learned.

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
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelMembership, Names}

  @negative [:frustrated, :asked_again, :edited]
  @named_done 5
  @named_open 3
  @named_stuck 3

  @type week :: %{from: DateTime.t(), to: DateTime.t()}

  @doc "Every fact the report states for `week`, read at `now` (what is stuck then)."
  @spec read(week(), DateTime.t()) :: map()
  def read(%{from: from, to: to} = week, %DateTime{} = now) do
    requests = requests(from, to)
    {done, open} = Enum.split_with(requests, &(&1.standing == :finished))

    %{
      week: week,
      requests: %{total: length(requests), finished: length(done)},
      replied: replied(from, to),
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

  # The messages routing answered on the spot that week: a reply without a
  # request behind it.
  defp replied(from, to) do
    Repo.aggregate(
      from(entry in Entry,
        where:
          entry.execution_mode == :live and entry.decision_action == :quick_reply and
            entry.inserted_at >= ^from and entry.inserted_at < ^to
      ),
      :count
    )
  end

  # The draft PRs Ryker opened that week.
  defp pull_requests(from, to) do
    Repo.aggregate(
      from(publication in Publication,
        join: episode in Episode,
        on: episode.id == publication.episode_id and episode.execution_mode == :live,
        where: publication.published_at >= ^from and publication.published_at < ^to
      ),
      :count
    )
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
