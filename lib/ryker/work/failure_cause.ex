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

  alias Ryker.InspectionRedactor

  # The saved error keeps a Coop refusal as the third element of an inspected
  # tuple, wherever the retry ladder nested it. An unterminated literal is a
  # truncated detail, and a half sentence is not a cause.
  @coop_refusal ~r/:coop_operation_failed, "(?:[^"\\]|\\.)*", "((?:[^"\\]|\\.)*)"/

  # A provider that limits the worker's model account keeps its own sentence,
  # which says whether it is a moment's throttle or a usage cap, and until
  # when. Coop has worded it two ways (recorded 2026-09-09 and 2026-09-26).
  @provider_limit ~r/"provider (?:rate limited the turn|limit prevented the turn): ((?:[^"\\]|\\.)*)"/

  # A repository whose submodule comes from a repository Ryker was never given,
  # as the saved term names both: the task's own or a read-only one from its
  # environment (tenantcorp/tenant-core and skypjack/entt, 2026-10-03).
  @refused_source ~r/\{:coop_worker_(source|companion)_refused, "([A-Za-z0-9._\/-]+)", "([A-Za-z0-9._\/-]+)"\}/

  # The saved error names one of these conditions somewhere in its term, and
  # each says the same thing wherever it nests.
  @explained [
    {"Failed to refresh token",
     %{
       cause:
         "The model provider rejected the worker's sign-in, so the call never reached the model.",
       next_step: "Sign the worker in to its model account again, then retry."
     }},
    {"coop_worker_capacity_unavailable",
     %{
       cause:
         "No eligible worker with available capacity was found, so this task was never placed on one.",
       next_step:
         "Make a worker for this repository available again: enrolled, reporting and not " <>
           "draining. Then retry this task."
     }},
    # Andrew, 2026-10-03, of a tenant task that stopped this way: "I don't see
    # error reason, it's super hard to tell what went wrong for a human".
    {"coop_worker_source_unavailable",
     %{
       cause:
         "Ryker couldn't get the repository's code from GitHub to give the worker, " <>
           "and stopped after retrying for about two minutes.",
       next_step:
         "This is usually brief, for example right after repositories are added. Run the task " <>
           "again. If it stops the same way, check the repository's page and that the GitHub " <>
           "App can still reach it."
     }},
    {"coop_worker_command_timeout",
     %{
       cause: "The worker did not take or finish one of this task's commands in time.",
       next_step:
         "Check that the worker is connected and polling, then retry this task. The command is saved, so the retry picks up the same one."
     }},
    {"work_remote_operation_in_flight",
     %{
       cause:
         "The host still treats an earlier worker operation for this session as unresolved, so it will not start another one.",
       next_step:
         "Confirm on the worker whether that operation finished and let the host reconcile it before retrying."
     }}
  ]

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

      refused = refused_source(detail) ->
        refused

      limit = provider_limit(detail) ->
        %{
          cause: "The model provider limited the worker's account: " <> limit,
          next_step:
            "Add credits to the model account the worker signs in with, or sign it in to another account, then retry."
        }

      true ->
        Enum.find_value(@explained, fn {needle, explanation} ->
          String.contains?(detail, needle) && explanation
        end)
    end
  end

  def explain(_detail), do: nil

  @doc """
  Whether the saved error says the model account the worker signs in with
  needs a person: it is limited, or its sign-in no longer works. No retry
  cures either.
  """
  @spec account_problem?(String.t() | nil) :: boolean()
  def account_problem?(detail) when is_binary(detail),
    do: provider_limit(detail) != nil or String.contains?(detail, "Failed to refresh token")

  def account_problem?(_detail), do: false

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
  defp coop_refusal(detail), do: provider_sentence(@coop_refusal, detail)
  defp provider_limit(detail), do: provider_sentence(@provider_limit, detail)

  defp refused_source(detail) do
    case Regex.run(@refused_source, detail, capture: :all_but_first) do
      ["companion", repository, submodule] ->
        %{
          cause:
            "#{repository} is in this task's environment and has a submodule from #{submodule}, " <>
              "which Ryker can't fetch. So the worker couldn't get #{repository}'s code.",
          next_step: "Take #{repository} out of the environment, then run the task again."
        }

      ["source", repository, submodule] ->
        %{
          cause:
            "#{repository} has a submodule from #{submodule}, which Ryker can't fetch. " <>
              "So the worker couldn't get the code.",
          next_step:
            "If #{submodule} belongs to an organization you manage, install the GitHub App " <>
              "there and add the repository to Ryker, then run the task again. Otherwise Ryker " <>
              "can't work on #{repository} yet."
        }

      _other ->
        nil
    end
  end

  defp provider_sentence(pattern, detail) do
    case Regex.run(pattern, detail, capture: :all_but_first) do
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
