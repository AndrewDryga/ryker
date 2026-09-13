defmodule Ryker.ControlPlane.EpisodeTrace.Learning do
  @moduledoc """
  "Learning": the background passes that read this episode's messages. A
  batch appears only when one of the episode's own inputs is a recorded
  member of it, and a cross-episode batch says how much of it belongs here.
  """

  import Ecto.Query
  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.ControlPlane.LearningActivity
  alias Ryker.Learning.InputMembership
  alias Ryker.Repo
  alias Ryker.State.LearningRun

  @doc """
  Learning is a peer of the work, not a step inside it: it runs on decided
  inputs whether or not this episode ever replied. A batch appears here only
  when one of this episode's own inputs is a recorded member of it, never
  because it shares a channel, and a cross-episode batch says how much of it
  belongs here rather than borrowing the rest.
  """
  def steps([]), do: []

  def steps(input_rows) do
    input_ids = Enum.map(input_rows, & &1.id)

    memberships =
      Repo.all(
        from(membership in InputMembership,
          where: membership.input_id in ^input_ids,
          select: {membership.batch_id, membership.input_id}
        )
      )

    local_counts =
      memberships
      |> Enum.group_by(&elem(&1, 0))
      |> Map.new(fn {batch, rows} -> {batch, length(rows)} end)

    batch_ids = Map.keys(local_counts)

    if batch_ids == [] do
      []
    else
      Repo.all(
        from(run in LearningRun,
          where: run.batch_id in ^batch_ids,
          order_by: [asc: run.inserted_at, asc: run.id],
          limit: 50
        )
      )
      |> Enum.map(&learning_step(&1, Map.get(local_counts, &1.batch_id, 0)))
    end
  end

  defp learning_step(run, local_inputs) do
    outcome = learning_outcome(run)
    total_inputs = length(List.wrap(run.inputs))

    step("learning-#{run.id}", :learning, run.applied_at || run.inserted_at, %{
      actor: "Ryker",
      stage: "Learning",
      state: outcome.label,
      title: "Learning",
      summary: outcome.summary,
      tone: outcome.tone,
      href: LearningActivity.attempt_path(run.batch_id, run.id),
      details:
        compact_details([
          {"Messages read", learning_membership(total_inputs, local_inputs)},
          {"Model", get_in(run.producer || %{}, ["target"]) || "Not recorded"},
          {"Prompt", if(run.prompt_sha256, do: short_digest(run.prompt_sha256))},
          {"Result", if(run.result_sha256, do: short_digest(run.result_sha256))},
          {"Outcome", outcome.detail},
          {"Applied", run.applied_at},
          {"Bodies", if(run.pruned_at, do: "Expired #{timestamp_precise(run.pruned_at)}")}
        ])
    })
  end

  # A batch can read inputs from several episodes. Saying "3 messages" when one
  # of them is this episode's would credit this page with another one's sources.
  defp learning_membership(total, local) when total > local,
    do: "#{local} of #{total} from this request"

  defp learning_membership(total, _local), do: plural(total, "message")

  defp learning_outcome(%LearningRun{status: :applied, result: result}) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{"updates" => updates}} when is_list(updates) ->
        {deferred, saved} = Enum.split_with(updates, &match?(%{"action" => "defer"}, &1))

        cond do
          saved == [] and deferred == [] ->
            %{
              label: "no change",
              summary: "Nothing new to save from these messages.",
              tone: nil,
              detail: "Empty result"
            }

          saved == [] ->
            %{
              label: "deferred",
              summary: "The model deferred every judgment; nothing was saved.",
              tone: nil,
              detail: "#{length(deferred)} deferred"
            }

          true ->
            %{
              label: "knowledge saved",
              summary: "Saved #{plural(length(saved), "topic update")} from these messages.",
              tone: :good,
              detail: "#{length(saved)} saved · #{length(deferred)} deferred"
            }
        end

      _unreadable ->
        %{label: "applied", summary: "The learning result was applied.", tone: :good, detail: nil}
    end
  end

  defp learning_outcome(%LearningRun{status: :applied}),
    do: %{label: "applied", summary: "The learning result was applied.", tone: :good, detail: nil}

  defp learning_outcome(%LearningRun{status: :rejected, error_code: code}),
    do: %{
      label: "rejected",
      summary: "The host rejected this learning result. Nothing was saved.",
      tone: :warn,
      detail: error_label(code)
    }

  defp learning_outcome(%LearningRun{status: :stale, error_code: code}),
    do: %{
      label: "stale",
      summary: "The sources or the target topic changed before this result could be applied.",
      tone: :warn,
      detail: error_label(code)
    }

  defp learning_outcome(%LearningRun{status: status, error_code: code}),
    do: %{
      label: human(status),
      summary: "A learning pass read these messages. It sent no reply.",
      tone: nil,
      detail: error_label(code)
    }
end
