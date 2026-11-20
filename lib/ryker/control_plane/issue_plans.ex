defmodule Ryker.ControlPlane.IssuePlans do
  @moduledoc "Repository writers review, edit and approve one saved issue plan here."
  alias Ryker.ControlPlane.{Assets, PublicPage}
  alias Ryker.GitHubActions

  @salt "github-issue-plan"

  def call(conn, :issue, token, options), do: show(conn, token, options)

  def call(conn, action, token, options) do
    %{"binding" => binding, "number" => text} = conn.path_params

    with {number, ""} when number > 0 <- Integer.parse(text),
         {:ok, %{binding: ^binding, number: ^number, expected: expected}} <-
           Phoenix.Token.verify(conn.secret_key_base, @salt, conn.params["snapshot"],
             max_age: 3600
           ),
         {:ok, _result} <- submit(action, conn, token, number, expected, options) do
      PublicPage.go(conn, path(binding, number))
    else
      {:error, reason} -> show(conn, token, options, reason)
      _invalid -> show(conn, token, options, :invalid_action_link)
    end
  end

  defp submit(:edit_issue_plan, conn, token, number, expected, options) do
    GitHubActions.edit_issue_plan(
      conn.path_params["binding"],
      token,
      number,
      expected,
      conn.params["body"],
      options
    )
  end

  defp submit(:issue_action, conn, token, number, expected, options) do
    kind =
      case conn.params["action"] do
        "make_plan" -> :make_plan
        "triage_issue" -> :triage_issue
        "build_issue" -> :build_issue
        "implement_plan" -> :implement_plan
        _invalid -> nil
      end

    if kind do
      GitHubActions.start_issue(
        conn.path_params["binding"],
        token,
        number,
        kind,
        expected,
        options
      )
    else
      {:error, :invalid_action_link}
    end
  end

  defp show(conn, token, options, error \\ nil) do
    options =
      case Integer.parse(conn.path_params["before"] || "") do
        {revision, ""} when revision > 0 -> Keyword.put(options, :history_before, revision)
        _latest -> options
      end

    with {number, ""} when number > 0 <- Integer.parse(conn.path_params["number"]),
         {:ok, view} <- GitHubActions.issue(conn.path_params["binding"], token, number, options) do
      snapshot =
        Phoenix.Token.sign(conn.secret_key_base, @salt, %{
          binding: view.binding,
          number: number,
          expected: view.expected
        })

      render(conn, view, snapshot, error)
    else
      _unavailable ->
        PublicPage.page(
          conn,
          409,
          "Issue unavailable",
          "<p>GitHub could not confirm this open issue and your write access. Open the issue on GitHub and sign in again.</p>"
        )
    end
  end

  defp render(conn, view, snapshot, error) do
    action_path = path(view.binding, view.issue["number"])

    notice =
      if error,
        do: ["<p role=\"alert\" class=\"github-action-error\">", message(error), "</p>"],
        else: ""

    PublicPage.page(conn, if(error, do: 409, else: 200), view.issue["title"], [
      "<div class=\"github-action-page\"><p><a target=\"_blank\" rel=\"noopener noreferrer\" href=\"",
      PublicPage.escape(view.issue["url"]),
      "\">Open issue #",
      to_string(view.issue["number"]),
      " on GitHub</a></p>",
      notice,
      "<details><summary>Issue details</summary><pre>",
      PublicPage.escape(view.issue["body"] || ""),
      "</pre></details>",
      status(view),
      "<p><a href=\"",
      action_path,
      "\">Refresh status</a> · Progress is also posted in the GitHub issue linked above.</p>",
      triage(view.progress),
      if(view.plan || is_nil(view.implementation),
        do: plan(view.plan, conn, action_path, snapshot, view.workflow.id),
        else: ""
      ),
      "<form class=\"github-plan-actions\" method=\"post\" action=\"",
      action_path,
      "\">",
      fields(action_path, snapshot),
      controls(view.plan, view.progress, view.implementation),
      "</form>",
      history(view, action_path),
      "</div><script type=\"module\" src=\"",
      Assets.path("github-actions.mjs"),
      "\"></script>"
    ])
  end

  defp status(%{progress: %{"url" => url} = progress}) do
    text =
      if progress["status"] == "publication_needs_attention" do
        "The fix was pushed, but the PR changed or could not be verified afterward. Review Ryker's publication report."
      else
        "Pull request ready."
      end

    [
      "<p role=\"status\">",
      text,
      " <a target=\"_blank\" rel=\"noopener noreferrer\" href=\"",
      PublicPage.escape(url),
      "\">View pull request</a></p>"
    ]
  end

  defp status(view), do: ["<p role=\"status\">", PublicPage.escape(view.progress_text), "</p>"]

  defp triage(%{"triage" => result}) do
    related =
      Enum.map(result["related"], fn item ->
        [
          "<li><a href=\"",
          PublicPage.escape(item["url"]),
          "\" target=\"_blank\" rel=\"noopener noreferrer\">#",
          to_string(item["number"]),
          "</a> · ",
          PublicPage.escape(String.replace(item["relation"], "_", " ")),
          ": ",
          PublicPage.escape(item["evidence"]),
          "</li>"
        ]
      end)

    [
      "<section aria-label=\"Issue triage\"><h2>Issue triage</h2><pre>",
      PublicPage.escape(result["summary"]),
      "</pre><ul>",
      related,
      "</ul><p>",
      PublicPage.escape(Enum.join(result["labels"], ", ")),
      " · ",
      PublicPage.escape(result["labels_status"]),
      "</p></section>"
    ]
  end

  defp triage(_progress), do: ""

  defp plan(nil, _conn, _path, _snapshot, _workflow) do
    "<p>Triage this issue checks related reports and missing details. Make a plan to review the steps before code changes start. Build this starts work directly from the issue.</p>"
  end

  defp plan(plan, conn, path, snapshot, workflow) do
    submitted = conn.params["body"] || ""

    [
      "<h2>Plan · version ",
      to_string(plan.revision),
      "</h2>",
      "<p>Saved against commit <code>",
      String.slice(plan.source_commit, 0, 12),
      "</code>. Editing saves a new version and does not change work already started.</p>",
      "<form method=\"post\" action=\"",
      path,
      "/edit\">",
      fields(path, snapshot),
      "<label for=\"issue-plan-body\">Plan</label><textarea id=\"issue-plan-body\" name=\"body\" rows=\"14\" maxlength=\"16000\" data-saved-plan=\"",
      PublicPage.escape(plan.body),
      "\" data-workflow-id=\"",
      workflow,
      "\" data-plan-id=\"",
      plan.id,
      "\" required>",
      PublicPage.escape(plan.body),
      "</textarea><p><button class=\"ui-button secondary\" type=\"submit\" data-save-plan>Save new version</button></p></form>",
      "<p data-plan-edit-notice>Implement plan starts the saved version shown above. Save your edits first.</p>",
      "<section data-plan-draft-recovery hidden><h3>Unsaved draft to review</h3><pre data-recovered-plan data-server-draft=\"",
      PublicPage.escape(submitted),
      "\"></pre>",
      "<button class=\"ui-button secondary\" type=\"button\" data-use-plan-draft>Use this draft in the editor</button> ",
      "<button class=\"ui-button secondary\" type=\"button\" data-discard-plan-draft>Discard draft</button></section>"
    ]
  end

  defp controls(_plan, %{"status" => status}, _implementation)
       when status in ~w(queued planning preparing building checking needs_attention needs_input) do
    "<p>Work is already in progress. Follow its status above before starting another action.</p>"
  end

  defp controls(nil, progress, implementation),
    do: [
      "<button class=\"ui-button primary\" type=\"submit\" name=\"action\" value=\"make_plan\">Make a plan</button> ",
      direct_build_action(implementation, progress),
      "<button class=\"ui-button secondary\" type=\"submit\" name=\"action\" value=\"triage_issue\">Triage this issue</button>"
    ]

  defp controls(plan, _progress, implementation),
    do: [
      implementation_action(plan, implementation),
      "<button class=\"ui-button secondary\" type=\"submit\" name=\"action\" value=\"make_plan\">Make a new plan</button> ",
      "<button class=\"ui-button secondary\" type=\"submit\" name=\"action\" value=\"triage_issue\">Triage this issue</button>"
    ]

  defp direct_build_action(nil, _progress) do
    "<button class=\"ui-button secondary\" type=\"submit\" name=\"action\" value=\"build_issue\">Build this</button> "
  end

  defp direct_build_action(%{"url" => url}, %{"url" => url}), do: ""

  defp direct_build_action(%{"url" => url}, _progress),
    do: [
      "<a class=\"ui-button secondary\" href=\"",
      PublicPage.escape(url),
      "\">View pull request for this build</a> "
    ]

  defp direct_build_action(_implementation, _progress),
    do: "<p>This issue already has an approved build.</p>"

  defp implementation_action(plan, nil),
    do: [
      "<button class=\"ui-button primary\" type=\"submit\" data-implement-plan name=\"action\" value=\"implement_plan\">Implement plan · version ",
      to_string(plan.revision),
      "</button> "
    ]

  defp implementation_action(plan, %{"url" => url}) do
    [
      "<a class=\"ui-button secondary\" href=\"",
      PublicPage.escape(url),
      "\">View pull request for version ",
      to_string(plan.revision),
      "</a> "
    ]
  end

  defp implementation_action(_plan, _existing),
    do: "<p>This plan version has already been approved.</p>"

  defp history(view, path) do
    versions = Enum.reject(view.plans, &(&1.id == view.workflow.current_plan_id))

    [
      Enum.map(versions, fn plan ->
        [
          "<details><summary>Earlier plan · version ",
          to_string(plan.revision),
          "</summary><pre class=\"github-finding-body\">",
          PublicPage.escape(plan.body),
          "</pre></details>"
        ]
      end),
      if(view.history_before,
        do: [
          "<p><a href=\"",
          path,
          "/history/",
          to_string(view.history_before),
          "\">View earlier versions</a></p>"
        ],
        else: ""
      )
    ]
  end

  defp fields(path, snapshot),
    do: [
      PublicPage.csrf(),
      "<input type=\"hidden\" name=\"return_to\" value=\"",
      path,
      "\"><input type=\"hidden\" name=\"snapshot\" value=\"",
      PublicPage.escape(snapshot),
      "\">"
    ]

  defp path(binding, number), do: "/github/actions/issue/#{URI.encode(binding)}/#{number}"

  defp message(reason) when reason in [:plan_changed, :issue_changed],
    do: "The issue or plan changed. Review the current version before saving or starting."

  defp message(:invalid_plan), do: "Enter a plan of at most 16,000 bytes."

  defp message(:issue_build_too_large) do
    "This report is too long for a direct build. Choose Make a plan, then review and implement the saved plan."
  end

  defp message(:issue_work_in_progress),
    do: "Work for this issue is already running. Follow its progress on GitHub."

  defp message(:plan_required), do: "Make a plan before implementing it."

  defp message(_reason),
    do: "This action could not start. Review the current issue and try again."
end
