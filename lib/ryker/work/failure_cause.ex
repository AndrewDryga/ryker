defmodule Ryker.Work.FailureCause do
  @moduledoc """
  What a saved work error says went wrong, in the host's own words.

  `Turn.last_error_detail` is an inspected internal term: the enum, the tuple
  and any identifier it carries are the host's bookkeeping, and none of them is
  an answer for a reader. Every operator surface that describes a blocked turn
  asks this module instead, so the recovery brief, the stage ledger and the
  Slack card describe one failure the same way, and a provider's own sentence
  inside the term is unescaped, redacted and bounded exactly once.

  A detail that names nothing returns `nil`: each surface keeps its own generic
  explanation for that, rather than inventing a cause the host does not have.
  """

  alias Ryker.ControlPlane.InspectionRedactor

  # The saved error keeps a Coop refusal as the third element of an inspected
  # tuple, wherever the retry ladder nested it. An unterminated literal is a
  # truncated detail, and a half sentence is not a cause.
  @coop_refusal ~r/:coop_operation_failed, "(?:[^"\\]|\\.)*", "((?:[^"\\]|\\.)*)"/

  @doc """
  The cause a saved execution error names and the step that answers it.

  Reading only `last_error_code` answered "no specific cause" to a refusal the
  host was holding word for word, leaving the operator with nothing to do.
  """
  @spec explain(String.t() | nil) :: %{cause: String.t(), next_step: String.t()} | nil
  def explain(detail) when is_binary(detail) do
    cond do
      refusal = coop_refusal(detail) ->
        %{
          cause: "The worker rejected the operation: " <> refusal,
          next_step: "Correct the condition the worker named, then retry this task."
        }

      String.contains?(detail, "coop_worker_capacity_unavailable") ->
        %{
          cause:
            "No eligible worker with available capacity was found, so this task was never placed on one.",
          next_step:
            "Make a worker for this repository available again — enrolled, reporting and not draining — then retry this task."
        }

      String.contains?(detail, "coop_worker_command_timeout") ->
        %{
          cause: "The worker did not take or finish one of this task's commands in time.",
          next_step:
            "Check that the worker is connected and polling, then retry this task. The command is saved, so the retry picks up the same one."
        }

      String.contains?(detail, "work_remote_operation_in_flight") ->
        %{
          cause:
            "The host still treats an earlier worker operation for this session as unresolved, so it will not start another one.",
          next_step:
            "Confirm on the worker whether that operation finished and let the host reconcile it before retrying."
        }

      true ->
        nil
    end
  end

  def explain(_detail), do: nil

  # The checkpoint guard's refusal, as the dispatcher records it: a blocked turn
  # carries the code before the term, a deferred one the term alone.
  @checkpoint_unsupported [
    "invalid_work_executor: {:invalid_work_executor, :workspace_checkpoint_api}",
    "{:invalid_work_executor, :workspace_checkpoint_api}"
  ]

  @doc """
  Whether the saved error is the executor refusing repository work on a worker
  connection that cannot save a workspace checkpoint.

  That refusal is a host configuration problem, not a failed task, and every
  surface that says so reads it from here.
  """
  @spec checkpoint_unsupported?(String.t() | nil) :: boolean()
  def checkpoint_unsupported?(detail), do: detail in @checkpoint_unsupported

  # The refusal is a provider's own sentence inside an inspected tuple, so it is
  # unescaped back out of that literal, then redacted and bounded like any other
  # untrusted text an operator surface displays.
  defp coop_refusal(detail) do
    case Regex.run(@coop_refusal, detail, capture: :all_but_first) do
      [escaped] ->
        escaped
        |> Macro.unescape_string()
        |> InspectionRedactor.artifact(max_bytes: 500)
        |> Map.fetch!(:text)

      nil ->
        nil
    end
  end
end
