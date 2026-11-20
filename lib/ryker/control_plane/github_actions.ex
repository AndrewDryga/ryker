defmodule Ryker.ControlPlane.GitHubActions do
  @moduledoc "Small repository action pages, separate from operator-console sign-in."
  @behaviour Plug
  import Plug.Conn
  alias Ryker.ControlPlane.{Assets, BrowserResults, EngineeringOffer, IssuePlans, PublicPage}
  alias Ryker.GitHubActions
  alias Ryker.Wording

  @session "_ryker_github_user"
  @challenge "_ryker_github_challenge"
  @scope "/github/actions"
  @snapshot_salt "github-review-selection"

  @impl true
  def init(action), do: action

  @impl true
  def call(conn, {action, options}) do
    conn =
      conn
      |> fetch_cookies(encrypted: [@session, @challenge])
      |> put_private(:github_action_options, options)

    route(conn, action)
  end

  def call(conn, action), do: call(conn, {action, []})

  defp route(conn, :sign_in) do
    case GitHubActions.begin_sign_in(conn.params["return_to"], System.system_time(:second)) do
      {:ok, url, challenge} ->
        conn |> put_resp_cookie(@challenge, challenge, cookie_options(600)) |> PublicPage.go(url)

      {:error, reason} ->
        refused(conn, reason)
    end
  end

  defp route(conn, :callback) do
    challenge = conn.cookies[@challenge] || %{}
    conn = delete_resp_cookie(conn, @challenge, path: @scope)
    now = System.system_time(:second)

    case GitHubActions.finish_sign_in(challenge, conn.params, now) do
      {:ok, token} ->
        session = %{"token" => token, "expires_at" => now + 3600}

        conn
        |> put_resp_cookie(@session, session, cookie_options(3600))
        |> PublicPage.go(challenge["return_path"])

      {:error, reason} ->
        refused(conn, reason)
    end
  end

  defp route(conn, action)
       when action in [
              :review,
              :fix_review,
              :issue,
              :issue_action,
              :edit_issue_plan,
              :engineering_offer,
              :confirm_engineering_offer,
              :browser_results,
              :result_image
            ] do
    case session_token(conn) do
      {:ok, token} -> authenticated(conn, action, token)
      :error -> sign_in_page(conn)
    end
  end

  defp authenticated(conn, action, token) when action in [:browser_results, :result_image],
    do: BrowserResults.call(conn, action, token, conn.private.github_action_options)

  defp authenticated(conn, action, token)
       when action in [:issue, :issue_action, :edit_issue_plan],
       do: IssuePlans.call(conn, action, token, conn.private.github_action_options)

  defp authenticated(conn, action, token)
       when action in [:engineering_offer, :confirm_engineering_offer],
       do: EngineeringOffer.call(conn, action, token, conn.private.github_action_options)

  defp authenticated(conn, :review, token) do
    %{"binding" => binding, "number" => number, "head" => head, "mode" => mode} = conn.path_params

    with {number, ""} when number > 0 <- Integer.parse(number),
         {:ok, review} <-
           GitHubActions.review(binding, token, number, conn.private.github_action_options),
         true <- review.pull["headRefOid"] == head do
      review_page(conn, review, signed_snapshot(conn, review), mode)
    else
      false -> review_error(conn, token, :review_changed)
      {:error, reason} -> review_error(conn, token, reason)
      _invalid -> refused(conn, :invalid_action_link)
    end
  end

  defp authenticated(conn, :fix_review, token) do
    %{"binding" => binding, "number" => number_text} = conn.path_params

    with {number, ""} when number > 0 <- Integer.parse(number_text),
         {:ok, %{binding: ^binding, number: ^number, digest: digest}} <-
           Phoenix.Token.verify(conn.secret_key_base, @snapshot_salt, conn.params["snapshot"],
             max_age: 3600
           ),
         {:ok, receipt} <-
           GitHubActions.fix_review(
             binding,
             token,
             number,
             digest,
             conn.params["findings"] || [],
             conn.private.github_action_options
           ) do
      PublicPage.page(conn, 202, "Review fixes queued", [
        "<p>Your selection is saved. Ryker will post progress and the result in the pull request.</p>",
        "<p><a href=\"",
        PublicPage.escape(receipt.url),
        "\">View progress on GitHub</a></p>"
      ])
    else
      {:error, reason} -> review_error(conn, token, reason)
      _invalid -> refused(conn, :invalid_action_link)
    end
  end

  defp signed_snapshot(conn, review) do
    Phoenix.Token.sign(conn.secret_key_base, @snapshot_salt, %{
      binding: review.binding,
      number: review.number,
      digest: review.snapshot
    })
  end

  defp review_error(conn, token, reason)
       when reason in [:empty_selection, :review_changed, :invalid_selection, :too_many_findings] do
    with {number, ""} <- Integer.parse(conn.path_params["number"]),
         {:ok, review} <-
           GitHubActions.review(
             conn.path_params["binding"],
             token,
             number,
             conn.private.github_action_options
           ) do
      # A changed snapshot is refreshed for an explicit second click. No edit to
      # an old selected comment can start work silently during this POST.
      ids = if is_list(conn.params["findings"]), do: conn.params["findings"], else: []
      findings = Enum.map(review.findings, &Map.put(&1, "selected", &1["thread_id"] in ids))

      review_page(
        conn,
        %{review | findings: findings},
        signed_snapshot(conn, review),
        "selected",
        reason
      )
    else
      _unavailable -> refused(conn, reason)
    end
  end

  defp review_error(conn, _token, reason), do: refused(conn, reason)

  defp session_token(conn) do
    case conn.cookies[@session] do
      %{"token" => token, "expires_at" => expires}
      when is_binary(token) and is_integer(expires) ->
        if expires > System.system_time(:second), do: {:ok, token}, else: :error

      _missing ->
        :error
    end
  end

  defp cookie_options(max_age) do
    [
      encrypt: true,
      http_only: true,
      same_site: "Lax",
      path: @scope,
      max_age: max_age,
      secure: URI.parse(GitHubActions.callback_url()).scheme == "https"
    ]
  end

  defp sign_in_page(conn) do
    query = URI.encode_query(%{"return_to" => conn.params["return_to"] || conn.request_path})

    PublicPage.page(conn, 200, "Sign in with GitHub", [
      sign_in_description(conn),
      ~s(<a class="ui-button primary" href="/github/actions/sign-in?),
      PublicPage.escape(query),
      ~s(">Continue with GitHub</a>)
    ])
  end

  defp sign_in_description(%{path_info: ["github", "actions", "results" | _rest]}) do
    "<p>Sign in to view retained results. Your account needs read access to this repository.</p>"
  end

  defp sign_in_description(_conn) do
    "<p>Sign in to choose fixes or approve a plan. You need write access to this repository.</p>"
  end

  defp review_page(conn, review, snapshot, mode, error \\ nil) do
    count = Enum.count(review.findings, &(mode == "all" or &1["selected"]))
    maximum = GitHubActions.maximum_selected_findings()

    items =
      Enum.map(review.findings, fn finding ->
        checked = if mode == "all" or finding["selected"], do: " checked", else: ""

        [
          "<div class=\"github-finding\"><label class=\"github-finding-choice\"><input type=\"checkbox\" name=\"findings[]\" value=\"",
          PublicPage.escape(finding["thread_id"]),
          "\"",
          checked,
          "><span>",
          PublicPage.escape(finding["path"]),
          ":",
          PublicPage.escape(to_string(finding["line"])),
          "</span></label><p class=\"github-finding-body\">",
          PublicPage.escape(finding["body"]),
          "</p><a href=\"",
          PublicPage.escape(finding["url"]),
          "\">View finding on GitHub</a></div>"
        ]
      end)

    PublicPage.page(
      conn,
      if(error, do: 409, else: 200),
      "Choose fixes for PR ##{review.number}",
      [
        "<div class=\"github-action\"><p><a href=\"",
        PublicPage.escape(review.pull["url"]),
        "\">Open pull request #",
        Integer.to_string(review.number),
        "</a></p>",
        "<p>",
        if(mode == "all",
          do: "All current findings are selected.",
          else: "Your thumbs-ups are selected."
        ),
        " Choose up to ",
        Integer.to_string(maximum),
        " findings for one run. Ryker will update this PR.</p>",
        if(error,
          do: [
            "<p class=\"github-action-error\" role=\"alert\">",
            PublicPage.escape(error_message(error)),
            "</p>"
          ],
          else: ""
        ),
        "<form data-review-selection data-selection-limit=\"",
        Integer.to_string(maximum),
        "\" data-pr-number=\"",
        Integer.to_string(review.number),
        "\" method=\"post\" action=\"/github/actions/review/",
        PublicPage.escape(review.binding),
        "/",
        Integer.to_string(review.number),
        "\">",
        PublicPage.csrf(),
        "<input type=\"hidden\" name=\"return_to\" value=\"/github/actions/review/",
        PublicPage.escape(review.binding),
        "/",
        Integer.to_string(review.number),
        "/",
        PublicPage.escape(review.pull["headRefOid"]),
        "/selected\">",
        "<input type=\"hidden\" name=\"snapshot\" value=\"",
        PublicPage.escape(snapshot),
        "\">",
        "<fieldset><legend>Findings to fix</legend>",
        findings_or_empty(items),
        "</fieldset><p data-selection-count aria-live=\"polite\">",
        Integer.to_string(count),
        " selected</p>",
        "<button class=\"ui-button primary\" data-fix-selected type=\"submit\"",
        if(count == 0 or count > maximum, do: " disabled", else: ""),
        ">Fix ",
        Wording.count(count, "finding"),
        " in PR #",
        Integer.to_string(review.number),
        "</button></form></div>",
        "<script type=\"module\" src=\"",
        Assets.path("github-actions.mjs"),
        "\"></script>"
      ]
    )
  end

  defp findings_or_empty([]) do
    "<p>No current unresolved findings. Open the latest PR review to see what changed.</p>"
  end

  defp findings_or_empty(items), do: items

  defp refused(conn, reason) do
    PublicPage.page(conn, 409, "Action needs attention", [
      "<p>",
      PublicPage.escape(error_message(reason)),
      "</p>"
    ])
  end

  defp error_message(:github_sign_in_not_configured) do
    "GitHub sign-in is not configured yet. Ask a Ryker operator to connect it in Settings."
  end

  defp error_message(:repository_access_required) do
    "GitHub could not confirm your write access to this repository. Sign in again or ask a repository administrator."
  end

  defp error_message(:repository_work_not_ready) do
    "This repository is not ready to run work yet. Ask a Ryker operator to finish its setup."
  end

  defp error_message(:empty_selection) do
    "Choose at least one finding before starting."
  end

  defp error_message(:too_many_findings) do
    "Choose at most #{GitHubActions.maximum_selected_findings()} findings for one run. Uncheck some findings before starting."
  end

  defp error_message(:review_changed) do
    "The PR or its findings changed. Review the refreshed choices before starting."
  end

  defp error_message(:sign_in_expired) do
    "This sign-in expired. Open the action link again to start a fresh sign-in."
  end

  defp error_message(:sign_in_failed) do
    "GitHub could not complete sign-in. Open the action link again to retry."
  end

  defp error_message(_other) do
    "This action could not start. Open the latest action link and try again."
  end
end
