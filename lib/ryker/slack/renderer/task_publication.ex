defmodule Ryker.Slack.Renderer.TaskPublication do
  @moduledoc """
  The publication section of a task card: where the draft pull request stands
  and the exact recovery controls the host authorized for this generation.
  """

  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields

  @publication_controls ~w(publish open check retry update discard)
  # Why Ryker ended a publication itself; a person's discard has none.
  @discarded_reasons [nil, "review_session_closed"]

  @spec validate(map() | nil) :: :ok | {:error, term()}
  def validate(nil), do: :ok

  def validate(
        %{
          "automatic_fix" => automatic_fix,
          "blocked_reason" => _blocked_reason,
          "branch" => branch,
          "controls" => controls,
          "discarded_reason" => discarded_reason,
          "publication_ref" => publication_ref,
          "pull_request_number" => number,
          "pull_request_url" => url,
          "recovery_generation" => recovery_generation,
          "status" => status,
          "unverified" => unverified
        } = publication
      )
      when map_size(publication) == 11 and discarded_reason in @discarded_reasons do
    with :ok <- bounded_text(status, 120),
         :ok <- optional_bounded_text(automatic_fix, 300),
         :ok <- optional_bounded_text(publication["blocked_reason"], 700),
         :ok <- optional_bounded_text(branch, 512),
         :ok <- publication_controls(controls),
         :ok <- optional_publication_reference(publication_ref),
         :ok <- optional_positive_integer(number),
         :ok <- optional_positive_integer(recovery_generation),
         :ok <- optional_bounded_text(unverified, 500),
         :ok <- optional_https_url(url) do
      publication_control_identity(
        controls,
        publication_ref,
        number,
        url,
        recovery_generation
      )
    end
  end

  def validate(_publication), do: {:error, :invalid_task_publication}

  @spec blocks(String.t(), String.t(), map() | nil) :: [map()]
  def blocks(_task_ref, _repository, nil), do: []

  def blocks(task_ref, repository, %{
        "automatic_fix" => automatic_fix,
        "blocked_reason" => blocked_reason,
        "branch" => branch,
        "controls" => controls,
        "discarded_reason" => discarded_reason,
        "publication_ref" => publication_ref,
        "pull_request_number" => number,
        "pull_request_url" => url,
        "recovery_generation" => recovery_generation,
        "status" => status,
        "unverified" => unverified
      }) do
    detail =
      if is_binary(url) and is_integer(number),
        do: " · #{link(url, "Open draft PR ##{number}")}",
        else: ""

    # The host's own line for a fix round Ryker is running on the refusal
    # (`Ryker.Publication.FixLoop`) says what the blocked status would not.
    message =
      cond do
        is_binary(automatic_fix) -> escape(automatic_fix)
        status == "discarded" -> discarded_message(discarded_reason)
        status == "blocked" -> blocked_message(controls, unverified, blocked_reason)
        true -> publication_status_message(status, controls, unverified)
      end

    summary = section("#{message}#{detail}#{publication_branch_line(status, branch)}")

    buttons =
      Enum.map(controls, fn
        "publish" ->
          button(
            "ryker_task_publish",
            "Create draft PR",
            "#{task_ref}|#{publication_ref}",
            "primary",
            "Create draft pull request",
            publish_confirmation(repository, unverified),
            "Create draft PR"
          )

        "open" ->
          url_button("ryker_open_publication", "Open PR", publication_ref, url)

        "check" ->
          plain_button(
            "ryker_task_check",
            "Check delivery",
            "#{task_ref}|#{publication_ref}"
          )

        "retry" ->
          button(
            "ryker_task_retry_publication",
            "Retry publication",
            "#{task_ref}|#{publication_ref}|#{recovery_generation}",
            "primary",
            "Retry publication workflow",
            "Retry this exact failed publication generation without changing its frozen review state?",
            "Retry"
          )

        "update" ->
          button(
            "ryker_task_update_publication",
            "Review latest state",
            "#{task_ref}|#{publication_ref}|#{recovery_generation}",
            nil,
            "Review latest repository state",
            "Invalidate this exact review and run a new review against the latest repository state?",
            "Review latest"
          )

        "discard" ->
          button(
            "ryker_task_discard_publication",
            "Discard candidate",
            "#{task_ref}|#{publication_ref}|#{recovery_generation}",
            "danger",
            "Discard publication candidate",
            "Discard this exact publication generation? Its review and remote evidence remain retained, but Ryker will stop updating it.",
            "Discard"
          )
      end)

    if buttons == [],
      do: [summary],
      else: [summary, actions("#{task_ref}:publication", buttons)]
  end

  # A draft-authorized task never rests in "reviewed": its checks passing is
  # enough for the draft the confirming person already granted. What is left
  # here is a candidate nobody granted a draft for.
  defp publication_status_message("reviewed", _controls, _unverified),
    do:
      "The changes passed their checks. I don't have a draft-PR grant for this task, so open the draft when you want one."

  defp publication_status_message("published", _controls, nil),
    do: "Draft PR created. Open it to review the changes."

  # A draft opened because a check could not run stays explicitly unverified
  # after it exists. Saying only "open it to review the changes" is how an
  # unrun gate reads as a checked change one message later.
  defp publication_status_message("published", _controls, unverified),
    do:
      "Draft PR created from the saved change, but the checks still haven't finished (#{unverified}). It isn't verified, and a draft doesn't merge or deploy anything."

  defp publication_status_message("published_ready", _controls, _unverified),
    do: "Draft PR created. Sending the publication update."

  defp publication_status_message(status, controls, _unverified) do
    cond do
      "retry" in controls ->
        "PR preparation stopped after an error. Retry the saved step below."

      status == "publish_pending" ->
        "Creating the draft PR. Waiting for GitHub to confirm."

      true ->
        "Checking the changes before creating a PR. It takes a few minutes; this card updates when the check is done."
    end
  end

  # One line says what failed and why, above the buttons that act on it
  # (Andrew, 2026-09-28: "⚠️ PR creation failed: the repository's checks
  # failed on the committed change. [buttons]"). The reason is the host's own
  # words, set only when the card's sources may be shown.
  defp blocked_message(controls, unverified, reason) when is_binary(unverified) do
    if "publish" in controls,
      do:
        "I couldn't finish the checks (#{escape(unverified)}). The exact change is saved, so I can open it as an explicitly unverified draft pull request, or check the latest state again.",
      else: blocked_message(controls, nil, reason)
  end

  defp blocked_message(_controls, _unverified, reason) when is_binary(reason),
    do: ":warning: *PR creation failed:* #{escape(reason)}"

  defp blocked_message(_controls, _unverified, _reason), do: ":warning: *PR creation failed.*"

  # A closed worker session can never be reviewed, so Ryker ends that request
  # itself; the task's next finished run is checked afresh.
  defp discarded_message("review_session_closed"),
    do:
      "I stopped preparing the PR: the worker session holding these changes closed before they could be checked, so no PR was made from them. When the task runs again, its new changes are checked then."

  defp discarded_message(nil),
    do:
      "Someone discarded these changes, so I stopped preparing their PR. The review history is saved."

  defp publish_confirmation(repository, nil),
    do:
      "Publish the exact reviewed candidate to #{repository} as a draft pull request? This does not merge or deploy it."

  defp publish_confirmation(repository, unverified),
    do:
      "Open a draft pull request in #{repository} from this exact saved change? The checks did not finish (#{unverified}). A draft does not waive them, and it does not merge or deploy anything."

  # Which branch is stuck is a fact the host holds and the card withheld, so
  # "PR creation is blocked" sent the reader to a web console this installation
  # publishes no URL for. Only the blocked state needs it: every other state
  # either links the pull request or has no branch worth naming yet.
  defp publication_branch_line("blocked", branch) when is_binary(branch) and branch != "",
    do: " · `#{escape(branch)}`"

  defp publication_branch_line(_status, _branch), do: ""

  defp publication_controls(controls) do
    if unique_subset?(controls, @publication_controls),
      do: :ok,
      else: {:error, :invalid_publication_controls}
  end

  defp publication_control_identity(
         controls,
         publication_ref,
         number,
         url,
         recovery_generation
       ) do
    valid =
      Enum.all?(controls, fn
        "publish" ->
          is_binary(publication_ref)

        "open" ->
          is_binary(publication_ref) and is_integer(number) and is_binary(url)

        "check" ->
          is_binary(publication_ref) and is_integer(number) and is_binary(url)

        action when action in ~w(retry update discard) ->
          is_binary(publication_ref) and is_integer(recovery_generation)
      end)

    if valid, do: :ok, else: {:error, :invalid_publication_controls}
  end

  defp optional_publication_reference(nil), do: :ok

  defp optional_publication_reference(value) do
    if is_binary(value) and Regex.match?(~r/\Apublication:[A-Za-z0-9_.:-]{1,240}\z/, value),
      do: :ok,
      else: {:error, :invalid_publication_reference}
  end
end
