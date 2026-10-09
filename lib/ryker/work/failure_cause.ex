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
  # each says the same thing wherever it nests. `depends` says what a retry
  # depends on, where the generic "the condition named above" would mislead.
  @explained [
    {"Failed to refresh token",
     %{
       cause:
         "The model provider rejected the worker's sign-in, so the call never reached the model.",
       next_step: "Sign the worker in to its model account again, then retry.",
       depends:
         "It works once the worker is signed in to its model account again. Ryker cannot see that from here."
     }},
    # Two tasks stopped on 2026-10-08 after Ryker refused every answer the
    # model gave (no valid answer existed for them, 79759944), and the
    # Failures page said the worker had ended them early.
    {"output_contract_failed",
     %{
       cause:
         "Ryker refused the model's answer three times in a row. Each one broke a rule " <>
           "Ryker checks before it uses an answer.",
       next_step:
         "Run it again. If it stops the same way, the request's page shows what each answer broke.",
       depends: "It works if the model's next answer passes Ryker's checks."
     }},
    # A briefing found stale on a later attempt stopped its task until
    # 82633a80 made it run again from the current one; the tasks it stopped
    # before read "stopped before Ryker could confirm why".
    {"work_knowledge_context_stale",
     %{
       cause:
         "The repository's briefing changed while the task ran, so Ryker stopped it rather " <>
           "than answer from the old one.",
       next_step: "Run the task again. It reads the briefing as it is now.",
       depends: "It works: a new run reads the current briefing."
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
    # A task keeps the settings it was admitted with. The tenant task stopped on
    # tenantcorp/tenant-core could not run again once tenant-core was taken out
    # of its environment (2026-10-03), and its page named no cause.
    {"coop_worker_job_settings_unavailable",
     %{
       cause:
         "Ryker's settings for this work changed after the task began, for example the " <>
           "repositories in its environment, so it couldn't start as it was set up.",
       next_step:
         "Run the task again. A task that never started picks up the settings as they are now."
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
  @spec explain(String.t() | nil) ::
          %{
            required(:cause) => String.t(),
            required(:next_step) => String.t(),
            optional(:depends) => String.t()
          }
          | nil
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
  What a card says of a blocked turn. A person's Stop saves the sentence its
  control wrote for the reader, and the card keeps it. Anything else saved a
  term: the card says the cause and next step `explain/1` names for it, or
  `fallback` when it names none. The task card printed the term whole
  ("coop_error: {:coop_error, 409, …}", 2026-10-09).
  """
  @spec summary(
          %{last_error_code: String.t() | nil, last_error_detail: String.t() | nil},
          String.t()
        ) :: String.t()
  def summary(%{last_error_code: "operator_stop", last_error_detail: detail}, _fallback)
      when is_binary(detail),
      do: detail

  def summary(%{last_error_detail: detail}, fallback) do
    case explain(detail) do
      %{cause: cause, next_step: next_step} -> cause <> "\n" <> next_step
      nil -> fallback
    end
  end

  @doc "The cause `explain/1` names for `detail` in words, or nil when it names none."
  @spec cause(String.t() | nil) :: String.t() | nil
  def cause(detail) do
    case explain(detail) do
      %{cause: cause} -> cause
      nil -> nil
    end
  end

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
