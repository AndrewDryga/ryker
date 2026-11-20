defmodule Ryker.Work.ValidationContext do
  @moduledoc """
  What the validator is told about a turn's answer: the episode's mode, its
  open goals and records, the Slack mentions the answer may use, whether its
  artifacts can be delivered, and whether a person is waiting for a visible
  reply. The executor builds this context while holding the owning episode
  and turn locks, then freezes the verdict before sending it to Coop.

  A reply is required only for live work whose current inputs include a
  person's. A continuation's original request was answered by an earlier
  accepted turn, so later automated observations never force a notification.
  """
  alias Ryker.Artifacts
  alias Ryker.Delivery
  alias Ryker.Episodes
  alias Ryker.GitHubActions
  alias Ryker.Records
  alias Ryker.Work
  alias Ryker.Work.{Custody, Turn}

  @doc "The context for `turn` of `episode`, before any artifact or workspace is known."
  @spec build(Episodes.Episode.t(), Turn.t()) :: %{String.t() => term()}
  def build(%Episodes.Episode{} = episode, %Turn{} = turn) do
    saved_issue_reply =
      GitHubActions.IssueInstructions.saved_reply?(%{episode: episode, turn: turn})

    %{
      "saved_issue_reply" => saved_issue_reply,
      "artifact_delivery_supported" => Artifacts.Outputs.delivery_supported?(episode),
      "artifact_metadata" => [],
      "artifact_refs" => [],
      "execution_mode" => Atom.to_string(episode.execution_mode),
      "guidance_requirements" => Work.GuidanceRequirements.context(turn),
      "open_required_goals" => Records.open_required_goals(episode.id),
      "records" =>
        Map.merge(
          Records.validation_records(episode.id),
          Delivery.PlatformActionCustody.validation_records(episode.id, turn.id)
        ),
      "slack_mentions" => Custody.Delivery.answer_mentions(episode, turn),
      "visible_reply_required" =>
        episode.execution_mode == :live and not saved_issue_reply and
          reply_required?(submission_context(turn)),
      "workspace" => nil
    }
  end

  defp submission_context(%Turn{submission: %{"context" => context}}), do: context
  defp submission_context(_unsubmitted), do: nil

  defp reply_required?(%{"mode" => "full", "inputs" => %{"items" => items}}),
    do: Enum.any?(items, &(&1["current"] == true and human_input?(&1)))

  defp reply_required?(%{"mode" => "continuation", "current_inputs" => %{"items" => items}}),
    do: Enum.any?(items, &human_input?/1)

  defp reply_required?(_context), do: false

  defp human_input?(%{"actor_ref" => actor_ref}) when is_binary(actor_ref),
    do: String.contains?(actor_ref, ":user:")

  defp human_input?(_input), do: false
end
