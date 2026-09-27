defmodule Ryker.WeeklyReport.Facts do
  @moduledoc """
  Everything the weekly report says, read from the database for one week and
  the week before it (`Ryker.WeeklyReport`), with no model anywhere: counts,
  and the few names and quotes the report shows beside them.

  A week is `%{from: from, to: to, previous_from: previous_from}`: this week
  is `from` up to `to`, the week before is `previous_from` up to `from`.
  Only live traffic counts; a shadow deployment's replays are not Ryker's
  week.

  The report is posted into one channel, so it names or quotes only what
  everyone in the workspace could read anyway: a request, a topic or a
  diagnosis from a public Slack channel Ryker is in, and a fact kept for the
  whole workspace. Anything from a direct message, a private channel, a
  shared channel, Chat or GitHub is counted and linked, never quoted
  (`public?/1`).
  """

  import Ecto.Query

  alias Ryker.Accounting.Query, as: Executions
  alias Ryker.ControlPlane.{ConversationMemory, FailureExplanation, FailureProjection}
  alias Ryker.ControlPlane.FeedbackProjection
  alias Ryker.Episodes.Episode
  alias Ryker.Feedback.Signal
  alias Ryker.Improvement
  alias Ryker.Improvement.Candidate
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.InspectionRedactor
  alias Ryker.Knowledge.ConversationKnowledge
  alias Ryker.Memories.MemoryEntry
  alias Ryker.Repo
  alias Ryker.Slack.ChannelMembership

  @negative [:frustrated, :asked_again, :edited]
  @named 3
  # A diagnosis that names a fault; "not a problem" and "unclear" say none.
  @faults [:host_bug, :prompt_bug, :model_mistake]

  @type week :: %{from: DateTime.t(), to: DateTime.t(), previous_from: DateTime.t()}

  @doc "Every fact the report states for `week`, read at `now` (the failures open then)."
  @spec read(week(), DateTime.t()) :: map()
  def read(%{from: from, to: to, previous_from: previous_from} = week, %DateTime{} = now) do
    %{
      week: week,
      requests: %{
        messages: messages(from, to),
        previous_messages: messages(previous_from, from).total,
        work: work(from, to),
        previous_work: work(previous_from, from).total
      },
      feedback: %{
        counts: feedback(from, to),
        previous: feedback(previous_from, from),
        frustrated: frustrated(from, to)
      },
      improvement: Map.put(Improvement.week(from, to), :sure, sure_diagnosis(from, to)),
      corrections: %{
        routing: routing_answers(from, to),
        previous_routing: routing_answers(previous_from, from),
        work: work_answers(from, to),
        previous_work: work_answers(previous_from, from),
        repeated: repeated_correction(from, to)
      },
      learned: %{
        facts: facts(from, to),
        previous_facts: facts(previous_from, from),
        topics: topics(from, to),
        previous_topics: topics(previous_from, from),
        newest: newest_learned(from, to)
      },
      failures: failures(now),
      cost: %{this: cost(from, to), previous: cost(previous_from, from)}
    }
  end

  @doc """
  Whether `conversation_ref` is a public Slack channel Ryker is in: joined,
  neither private nor shared with another organization. Only what came from
  one is named or quoted in a report posted to a channel.
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

  # -- Requests ----------------------------------------------------------------------

  # Each message or event routing read that week (an edit or a deletion is a
  # revision of one, not a message), by where it went: the decision routing
  # recorded, including one a later edit made stale, or where it waits.
  defp messages(from, to) do
    Repo.one(
      from(entry in Entry,
        where:
          entry.execution_mode == :live and entry.event_kind in [:message, :event] and
            entry.inserted_at >= ^from and entry.inserted_at < ^to,
        select: %{
          total: count(),
          answered: filter(count(), entry.decision_action in [:quick_reply, :react]),
          no_answer: filter(count(), entry.decision_action == :ignore),
          work:
            filter(count(), entry.decision_action in [:start_episode, :continue_episode, :reply]),
          blocked: filter(count(), entry.status == :blocked),
          reading: filter(count(), entry.status == :pending)
        }
      )
    )
  end

  # The requests Work took on that week, as each stands now. A request is
  # blocked while one of its turns waits on Failures.
  defp work(from, to) do
    Repo.one(
      from(episode in Episode,
        where:
          episode.execution_mode == :live and episode.inserted_at >= ^from and
            episode.inserted_at < ^to,
        select: %{
          total: count(),
          finished: filter(count(), episode.state == :complete),
          waiting: filter(count(), episode.state == :waiting_for_input),
          stopped: filter(count(), episode.state == :cancelled),
          blocked:
            filter(
              count(),
              episode.state in [:working, :waiting_for_event] and
                fragment(
                  "EXISTS (SELECT 1 FROM episode_work_turns AS turn WHERE turn.episode_id = ? AND turn.status = 'blocked')",
                  episode.id
                )
            ),
          going:
            filter(
              count(),
              episode.state in [:working, :waiting_for_event] and
                not fragment(
                  "EXISTS (SELECT 1 FROM episode_work_turns AS turn WHERE turn.episode_id = ? AND turn.status = 'blocked')",
                  episode.id
                )
            )
        }
      )
    )
  end

  # -- Feedback ----------------------------------------------------------------------

  defp feedback(from, to) do
    counts =
      from(signal in Signal,
        where: signal.occurred_at >= ^from and signal.occurred_at < ^to,
        group_by: signal.category,
        select: {signal.category, count()}
      )
      |> Repo.all()
      |> Map.new()

    counts = Map.new(Signal.categories(), &{&1, Map.get(counts, &1, 0)})

    Map.merge(counts, %{
      positive: counts.satisfied,
      negative: @negative |> Enum.map(&Map.fetch!(counts, &1)) |> Enum.sum()
    })
  end

  # The newest requests someone was frustrated with, each once, named as the
  # Feedback page names them where the report may name them.
  defp frustrated(from, to) do
    signals =
      from(signal in Signal,
        where:
          signal.category == :frustrated and signal.occurred_at >= ^from and
            signal.occurred_at < ^to,
        order_by: [desc: signal.occurred_at, desc: signal.id],
        limit: 50
      )
      |> Repo.all()
      |> Enum.uniq_by(&{&1.episode_id, &1.input_id})
      |> Enum.take(@named)

    requests = FeedbackProjection.requests(signals)

    Enum.map(signals, fn signal ->
      request = FeedbackProjection.request(requests, signal)
      public = public?(request.conversation)

      %{
        title: if(public, do: request.title),
        where: if(public, do: request.where),
        href: request.href
      }
    end)
  end

  # -- What to fix -------------------------------------------------------------------

  # The newest diagnosis Ryker was sure of that week, of a request that went
  # wrong and nobody dismissed; quoted only when the request was in a public
  # channel.
  defp sure_diagnosis(from, to) do
    case Repo.one(sure(from, to)) do
      nil ->
        nil

      candidate ->
        %{
          category: candidate.category,
          text:
            if(candidate.transport == "slack" and public?(candidate.conversation_ref),
              do: redacted(candidate.what_went_wrong)
            )
        }
    end
  end

  defp sure(from, to) do
    from(candidate in Candidate,
      where: is_nil(candidate.forgotten_at) and candidate.status != :dismissed,
      where: candidate.analysis == :done and candidate.confidence == :high,
      where: candidate.category in ^@faults,
      where: candidate.analyzed_at >= ^from and candidate.analyzed_at < ^to,
      order_by: [desc: candidate.analyzed_at, desc: candidate.id],
      limit: 1
    )
  end

  # -- Corrections -------------------------------------------------------------------

  # Routing's answers that week, and how many passed only after a correction:
  # a routing call records the attempt its answer passed on.
  defp routing_answers(from, to) do
    %{rows: [[answers, corrected]]} =
      Repo.query!(
        """
        SELECT count(*),
               count(*) FILTER (WHERE (attempt.response::jsonb ->> 'validation_attempt')::int > 1)
        FROM admission_attempts AS attempt
        JOIN ingress_inbox_entries AS entry ON entry.id = attempt.input_id
        WHERE entry.execution_mode = 'live'
          AND attempt.response IS NOT NULL
          AND attempt.response::jsonb ->> 'state' = 'completed'
          AND jsonb_typeof(attempt.response::jsonb -> 'validation_attempt') = 'number'
          AND attempt.inserted_at >= $1::timestamp AND attempt.inserted_at < $2::timestamp
        """,
        [naive(from), naive(to)]
      )

    %{answers: answers, corrected: corrected}
  end

  # Work's answers that week (each turn whose answer Ryker checked then), and
  # how many were sent back to be fixed at least once.
  defp work_answers(from, to) do
    %{rows: [[answers, corrected]]} =
      Repo.query!(
        """
        SELECT count(*), count(*) FILTER (WHERE checked.corrected)
        FROM (
          SELECT turn.id, bool_or(check_entry ->> 'verdict' = 'reject') AS corrected
          FROM episode_work_turns AS turn
          JOIN episode_kernel_episodes AS episode
            ON episode.id = turn.episode_id AND episode.execution_mode = 'live'
          CROSS JOIN LATERAL jsonb_array_elements(#{history()}) AS check_entry
          WHERE turn.updated_at >= $1::timestamp
            AND #{checked_at()} >= $1::timestamp AND #{checked_at()} < $2::timestamp
          GROUP BY turn.id
        ) AS checked
        """,
        [naive(from), naive(to)]
      )

    %{answers: answers, corrected: corrected}
  end

  # The correction Ryker gave Work's answers most often that week. Routing's
  # corrections go to the model inside its one call and are counted, not kept
  # word for word.
  defp repeated_correction(from, to) do
    case Repo.query!(
           """
           SELECT violation, count(*) AS times
           FROM (
             SELECT jsonb_array_elements_text(check_entry -> 'violations') AS violation,
                    #{checked_at()} AS checked_at
             FROM episode_work_turns AS turn
             JOIN episode_kernel_episodes AS episode
               ON episode.id = turn.episode_id AND episode.execution_mode = 'live'
             CROSS JOIN LATERAL jsonb_array_elements(#{history()}) AS check_entry
             WHERE turn.updated_at >= $1::timestamp
               AND check_entry ->> 'verdict' = 'reject'
               AND jsonb_typeof(check_entry -> 'violations') = 'array'
               AND #{checked_at()} >= $1::timestamp AND #{checked_at()} < $2::timestamp
           ) AS rejected
           GROUP BY violation
           ORDER BY times DESC, max(checked_at) DESC, violation
           LIMIT 1
           """,
           [naive(from), naive(to)]
         ) do
      %{rows: [[text, times]]} -> %{text: redacted(text), times: times}
      %{rows: []} -> nil
    end
  end

  defp history,
    do:
      "CASE WHEN jsonb_typeof(turn.validation_history::jsonb) = 'array' THEN turn.validation_history::jsonb ELSE '[]'::jsonb END"

  defp checked_at,
    do: "((check_entry ->> 'recorded_at')::timestamptz AT TIME ZONE 'UTC')"

  # -- Learned -----------------------------------------------------------------------

  defp facts(from, to) do
    Repo.aggregate(
      from(fact in MemoryEntry,
        where: fact.status == :active and fact.confirmed_at >= ^from and fact.confirmed_at < ^to
      ),
      :count
    )
  end

  defp topics(from, to) do
    Repo.aggregate(
      from(topic in ConversationKnowledge,
        where:
          is_nil(topic.forgotten_at) and topic.inserted_at >= ^from and topic.inserted_at < ^to
      ),
      :count
    )
  end

  # The newest facts and topics of the week the whole workspace may read: a
  # fact kept for the workspace or everywhere, a topic learned in a public
  # channel.
  defp newest_learned(from, to) do
    facts =
      from(fact in MemoryEntry,
        where:
          fact.status == :active and fact.confirmed_at >= ^from and fact.confirmed_at < ^to and
            fact.visibility in [:workspace, :global],
        order_by: [desc: fact.confirmed_at, desc: fact.id],
        limit: @named,
        select: %{at: fact.confirmed_at, name: fact.subject}
      )
      |> Repo.all()
      |> Enum.map(&Map.merge(&1, %{kind: :fact, path: "/memory"}))

    topics =
      from(topic in ConversationKnowledge,
        where:
          is_nil(topic.forgotten_at) and topic.inserted_at >= ^from and topic.inserted_at < ^to and
            topic.visibility == :public,
        order_by: [desc: topic.inserted_at, desc: topic.id],
        limit: @named,
        select: %{at: topic.inserted_at, id: topic.id, state: topic.state}
      )
      |> Repo.all()
      |> Enum.flat_map(&topic/1)

    (facts ++ topics)
    |> Enum.map(&%{&1 | name: redacted(&1.name)})
    |> Enum.reject(&(&1.name in [nil, ""]))
    |> Enum.sort_by(&DateTime.to_unix(&1.at, :microsecond), :desc)
    |> Enum.take(@named)
  end

  # A topic whose words expired has no title left to name.
  defp topic(%{state: %{"retention" => "pruned"}}), do: []

  defp topic(%{state: %{"title" => title}} = topic) when is_binary(title),
    do: [
      %{at: topic.at, kind: :topic, name: title, path: ConversationMemory.topic_path(topic.id)}
    ]

  defp topic(_topic), do: []

  # -- Needs a person ----------------------------------------------------------------

  # The failures open now that leave someone without a reply, an update or a
  # result, newest first, as the Failures page lists and explains them. A read
  # that failed is not "none".
  defp failures(now) do
    case FailureProjection.list(%{}) do
      {:ok, rows} ->
        people =
          rows
          |> Enum.map(&{&1, FailureExplanation.explain(&1, now)})
          |> Enum.filter(fn {_row, explanation} -> explanation.impact == :people end)

        %{
          people: length(people),
          partial: length(rows) == FailureProjection.page_size(),
          newest:
            people
            |> Enum.take(@named)
            |> Enum.map(fn {row, explanation} ->
              %{title: explanation.title, path: FailureExplanation.path(row)}
            end)
        }

      {:error, :unavailable} ->
        :unavailable
    end
  end

  # -- Cost --------------------------------------------------------------------------

  # What the week's model calls cost: reported by the provider, or estimated
  # from Settings › Model prices, as Usage & cost adds them up. Nil when
  # nothing that week was measured.
  defp cost(from, to) do
    executions =
      from(execution in Executions.executions(from, "live"),
        where: execution.recorded_at < ^to
      )

    totals =
      Repo.one(
        from(execution in subquery(executions),
          select: %{
            costed: filter(count(), execution.usage_cost_recorded),
            estimated: count(execution.estimated_cost_usd),
            cost: coalesce(sum(execution.usage_cost_usd), 0),
            estimate: coalesce(sum(execution.estimated_cost_usd), 0)
          }
        )
      )

    if totals.costed + totals.estimated > 0,
      do: %{
        amount: Decimal.add(decimal(totals.cost), decimal(totals.estimate)),
        estimated: totals.estimated > 0
      }
  end

  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  # -- Words -------------------------------------------------------------------------

  defp redacted(nil), do: nil

  defp redacted(text) do
    artifact = InspectionRedactor.artifact(text, max_bytes: 8_192)
    if artifact.text, do: String.trim(artifact.text)
  end

  defp naive(%DateTime{} = value), do: DateTime.to_naive(value)
end
