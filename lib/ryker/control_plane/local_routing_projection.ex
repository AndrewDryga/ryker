defmodule Ryker.ControlPlane.LocalRoutingProjection do
  @moduledoc """
  What the local routing model's page shows (`Ryker.ControlPlane.LocalRoutingPage`),
  counted by the database: the figures for a period, and the three tables of
  what the provider decided, what differed and why routing refused the rest,
  each row with its latest message.

  The page loaded every answer compared in its period, up to 10,000, each with
  the local model's answer and the provider's whole decision, and counted them
  in Elixir whenever a comparison settled (2026-10-04 review).
  """

  alias Ryker.ControlPlane.LocalRoutingReportQuery
  alias Ryker.LocalRouting
  alias Ryker.Repo

  # Why routing's checks refused an answer (`Ryker.LocalRouting.Verdict`),
  # as the rest of a sentence that starts "The local model".
  @refusals %{
    "empty" => "gave no answer",
    "cut_off" => "stopped before its answer was complete",
    "not_json" => "did not answer in routing's format",
    "rejected:unknown_candidate" => "named earlier work that was not offered",
    "rejected:action_not_allowed" => "chose something Ryker may not do with this message",
    "rejected:relation_not_allowed" =>
      "tied the message to earlier work in a way that is not allowed",
    "rejected:reaction_not_allowed" => "chose an emoji that is not allowed here",
    "rejected:reactions_not_available" => "chose an emoji where none may be added",
    "rejected:repository_not_allowed" => "chose a repository it may not use here",
    "rejected:repository_not_available" => "chose a repository where none may be used",
    "rejected:repository_required" => "started work without choosing a repository",
    "rejected:repository_source_not_available" => "chose a branch or commit that was not offered",
    "rejected:source_item_owner" => "took the message from the work it already belongs to",
    "rejected:occurrence_claimed" => "took the message from the work it already belongs to"
  }

  # What each compared field means for what Ryker does next.
  @field_words %{
    "action" => "what to do",
    "episode_ref" => "which earlier work",
    "relation" => "how it relates to earlier work",
    "work_class" => "kind of work",
    "repository" => "repository",
    "repository_source" => "branch or commit",
    "reactions" => "emoji"
  }

  # What a decision has Ryker do, named the way Usage names work types: a
  # reply is always a conversation, and new or continued work is an
  # investigation, standard or deep. `LocalRoutingReportQuery.compared/1` works it
  # out in SQL.
  @decision_names %{
    "start_deep" => "A deep investigation",
    "start" => "An investigation",
    "continue_deep" => "Earlier work, as a deep investigation",
    "continue" => "Earlier work",
    "reply" => "A reply",
    "quick_reply" => "A quick reply",
    "react" => "An emoji",
    "ignore" => "Leaving it",
    "unreadable" => "Something unreadable"
  }

  @doc """
  The figures, the three tables and the last settled comparison since `since`
  (nil for all time) in one execution scope (`live`, `shadow` or `all`), for
  the model saved now.
  """
  @spec project(DateTime.t() | nil, String.t()) :: map()
  def project(since, scope) do
    setting = LocalRouting.setting()
    comparisons = comparisons(since, scope, setting.model)
    compared = compared(comparisons)

    %{
      setting: setting,
      figures: figures(comparisons),
      last_settled: last_settled(comparisons),
      decisions: decisions(compared),
      differences: differences(compared),
      refusals: refusals(compared)
    }
  end

  # The period's comparisons in the page's scope, for the model saved now: a
  # model tried earlier is another model's record.
  defp comparisons(since, scope, model),
    do: LocalRoutingReportQuery.comparisons(since, scope, model)

  defp figures(comparisons) do
    comparisons
    |> LocalRoutingReportQuery.figures()
    |> Repo.one()
    |> nothing_agreed()
  end

  # With no answer agreeing, the provider spent nothing on agreed messages;
  # the sum over no rows would read as not measured.
  defp nothing_agreed(%{agreed: 0, provider_cost: %Decimal{}} = figures),
    do: %{figures | agreed_cost: Decimal.new(0)}

  defp nothing_agreed(figures), do: figures

  # The comparison that settled last, compared or given up: whether the
  # local model is answering now.
  defp last_settled(comparisons), do: Repo.one(LocalRoutingReportQuery.last_settled(comparisons))

  # The period's compared answers, each with what the provider decided and
  # what the local model decided, as kinds.
  defp compared(comparisons), do: LocalRoutingReportQuery.compared(comparisons)

  # Andrew, 2026-10-03, of the two lists this page had: "the way you built
  # those tables is piece of shit, they are useless, what i am supposed to do
  # or learn by looking at them?" Each table answers one question about
  # whether the local model could route instead: which of the provider's
  # decisions it matches, what it gets wrong when its answer is usable, and
  # why routing could not use the rest. Each row links to its latest message.

  # By what the provider decided: how many of the local model's answers were
  # usable and matched, and what it chose most often when it did not.
  defp decisions(compared) do
    instead =
      compared
      |> LocalRoutingReportQuery.instead()
      |> Repo.all()
      |> Enum.group_by(&elem(&1, 0), &Tuple.delete_at(&1, 0))

    latest = latest(compared, :kind)

    compared
    |> LocalRoutingReportQuery.decisions()
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        name: decision_name(row.kind),
        messages: row.messages,
        valid: row.valid,
        agreed: row.agreed,
        instead: instead(Map.get(instead, row.kind, [])),
        latest: Map.fetch!(latest, row.kind)
      }
    end)
    |> Enum.sort_by(&{-&1.messages, &1.name})
  end

  defp instead([]), do: nil

  defp instead(kinds) do
    {kind, times} = Enum.max_by(kinds, fn {kind, times} -> {times, kind} end)
    "#{decision_name(kind)} (#{times})"
  end

  # When its answer was usable but not the provider's: what differed, and
  # how often that was the only difference.
  defp differences(compared) do
    fields = LocalRoutingReportQuery.differing_fields(compared)

    latest = latest(fields, :field)

    fields
    |> LocalRoutingReportQuery.field_counts()
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        name: String.capitalize(Map.get(@field_words, row.field, row.field)),
        answers: row.answers,
        only: row.only,
        latest: Map.fetch!(latest, row.field)
      }
    end)
    |> Enum.sort_by(&{-&1.answers, &1.name})
  end

  # Why routing could not use its answer, the reasons that read the same
  # counted together.
  defp refusals(compared) do
    refused = LocalRoutingReportQuery.refused(compared)
    latest = latest(refused, :invalid_reason)

    refused
    |> LocalRoutingReportQuery.refusal_counts()
    |> Repo.all()
    |> Enum.group_by(fn {reason, _answers} -> refusal(reason) end)
    |> Enum.map(fn {words, reasons} ->
      %{
        name: String.capitalize(words),
        answers: Enum.sum_by(reasons, &elem(&1, 1)),
        latest:
          reasons
          |> Enum.map(&Map.fetch!(latest, elem(&1, 0)))
          |> Enum.max_by(& &1.at, DateTime)
      }
    end)
    |> Enum.sort_by(&{-&1.answers, &1.name})
  end

  # Each group's newest row, by when it was compared: the message its table
  # row opens.
  defp latest(rows, group),
    do: rows |> LocalRoutingReportQuery.latest(group) |> Repo.all() |> Map.new()

  defp refusal("decision:" <> _field), do: "gave a decision routing could not read"
  defp refusal(reason), do: Map.get(@refusals, reason, "gave an answer routing's checks refused")

  defp decision_name(kind), do: Map.fetch!(@decision_names, kind)
end
