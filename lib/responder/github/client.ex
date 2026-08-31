defmodule Responder.GitHub.Client do
  @moduledoc """
  Bounded GitHub REST adapter for durable comment and reaction delivery.

  Comment lookup never reports absence until every bounded page was inspected;
  this preserves the publisher's lost-response reconciliation guarantee.
  """

  @behaviour Responder.GitHub.API

  @fields [:http, :requester]
  @headers [
    {"accept", "application/vnd.github+json"},
    {"user-agent", "responder"},
    {"x-github-api-version", "2022-11-28"}
  ]
  @default_rate_limit_delay_seconds 60
  @maximum_pages 100
  @page_size 100
  @repository ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{http: term(), requester: module()}

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         client <- struct!(__MODULE__, attributes),
         true <- requester?(client.requester) do
      {:ok, client}
    else
      false -> {:error, {:invalid_github_client, :requester}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def find_issue_comment(client, repository, number, marker) do
    with :ok <- target(repository, number),
         :ok <- text(marker) do
      find_comments(
        client,
        fn page ->
          "/repos/#{repository}/issues/#{number}/comments?per_page=#{@page_size}&page=#{page}"
        end,
        fn comment -> marker_match(comment, marker) end
      )
    end
  end

  @impl true
  def create_issue_comment(client, repository, number, body) do
    with :ok <- target(repository, number),
         :ok <- text(body),
         {:ok, response} <-
           request(
             client,
             :post,
             "/repos/#{repository}/issues/#{number}/comments",
             %{"body" => body}
           ) do
      created_comment(response)
    end
  end

  @impl true
  def update_issue_comment(client, repository, comment_id, body) do
    update_comment(
      client,
      repository,
      comment_id,
      body,
      "/repos/#{repository}/issues/comments/#{comment_id}"
    )
  end

  @impl true
  def find_pull_review(client, repository, number, marker) do
    with :ok <- target(repository, number),
         :ok <- text(marker) do
      find_comments(
        client,
        fn page ->
          "/repos/#{repository}/pulls/#{number}/reviews?per_page=#{@page_size}&page=#{page}"
        end,
        fn review -> marker_match(review, marker) end
      )
    end
  end

  @impl true
  def create_pull_review(client, repository, number, body) do
    with :ok <- target(repository, number),
         :ok <- text(body),
         {:ok, response} <-
           request(client, :post, "/repos/#{repository}/pulls/#{number}/reviews", %{
             "body" => body,
             "event" => "COMMENT"
           }) do
      created_review(response)
    end
  end

  @impl true
  def update_pull_review(client, repository, number, review_id, body) do
    with :ok <- target(repository, number),
         :ok <- positive_id(review_id),
         :ok <- text(body),
         {:ok, response} <-
           request(
             client,
             :put,
             "/repos/#{repository}/pulls/#{number}/reviews/#{review_id}",
             %{"body" => body}
           ) do
      case response do
        %{body: %{"id" => ^review_id}, status: 200} -> :ok
        %{status: 200} -> {:error, {:github_protocol_error, :pull_review}}
        other -> api_error(other)
      end
    end
  end

  @impl true
  def find_review_reply(client, repository, number, root_id, marker) do
    with :ok <- target(repository, number),
         :ok <- positive_id(root_id),
         :ok <- text(marker) do
      find_comments(
        client,
        fn page ->
          "/repos/#{repository}/pulls/#{number}/comments?per_page=#{@page_size}&page=#{page}"
        end,
        fn comment -> review_marker_match(comment, root_id, marker) end
      )
    end
  end

  @impl true
  def create_review_reply(client, repository, number, root_id, body) do
    with :ok <- target(repository, number),
         :ok <- positive_id(root_id),
         :ok <- text(body),
         {:ok, response} <-
           request(
             client,
             :post,
             "/repos/#{repository}/pulls/#{number}/comments/#{root_id}/replies",
             %{"body" => body}
           ) do
      created_comment(response)
    end
  end

  @impl true
  def update_review_comment(client, repository, comment_id, body) do
    update_comment(
      client,
      repository,
      comment_id,
      body,
      "/repos/#{repository}/pulls/comments/#{comment_id}"
    )
  end

  @impl true
  def add_issue_comment_reaction(client, repository, comment_id, emoji_name) do
    reaction(
      client,
      repository,
      comment_id,
      emoji_name,
      "/repos/#{repository}/issues/comments/#{comment_id}/reactions"
    )
  end

  @impl true
  def add_review_comment_reaction(client, repository, comment_id, emoji_name) do
    reaction(
      client,
      repository,
      comment_id,
      emoji_name,
      "/repos/#{repository}/pulls/comments/#{comment_id}/reactions"
    )
  end

  @impl true
  def find_open_pull_request(client, repository, owner, branch) do
    with :ok <- repository(repository),
         :ok <- ref_component(owner),
         :ok <- ref_component(branch),
         query <-
           URI.encode_query(%{
             "head" => "#{owner}:#{branch}",
             "per_page" => @page_size,
             "state" => "open"
           }),
         {:ok, response} <- request(client, :get, "/repos/#{repository}/pulls?#{query}", nil) do
      case response do
        %{body: [], status: 200} ->
          :not_found

        %{body: [pull], status: 200} ->
          pull_request(pull)

        %{body: pulls, status: 200} when is_list(pulls) ->
          {:error, {:github_protocol_error, {:multiple_pull_requests, length(pulls)}}}

        other ->
          api_error(other)
      end
    end
  end

  @impl true
  def create_draft_pull_request(client, repository, title, body, head, base) do
    with :ok <- repository(repository),
         :ok <- text(title),
         :ok <- text(body),
         :ok <- ref_component(head),
         :ok <- ref_component(base),
         {:ok, response} <-
           request(client, :post, "/repos/#{repository}/pulls", %{
             "base" => base,
             "body" => body,
             "draft" => true,
             "head" => head,
             "title" => title
           }) do
      case response do
        %{body: pull, status: 201} -> pull_request(pull)
        other -> api_error(other)
      end
    end
  end

  @impl true
  def get_pull_request(client, repository, number) do
    with :ok <- target(repository, number),
         {:ok, response} <- request(client, :get, "/repos/#{repository}/pulls/#{number}", nil) do
      case response do
        %{body: pull, status: 200} -> pull_request(pull)
        other -> api_error(other)
      end
    end
  end

  @impl true
  def get_publication_status(client, repository, number) do
    with {:ok, pull} <- get_pull_request(client, repository, number),
         {:ok, check_runs} <- check_runs(client, repository, pull["head_sha"]),
         {:ok, commit_statuses} <- commit_statuses(client, repository, pull["head_sha"]) do
      checks = summarize_checks(check_runs, commit_statuses)

      {:ok,
       Map.merge(pull, %{
         "checks_failed" => checks.failed,
         "checks_passed" => checks.passed,
         "checks_state" => checks.state,
         "checks_total" => checks.total,
         "checks_url" => "https://github.com/#{repository}/pull/#{number}/checks"
       })}
    end
  end

  defp find_comments(client, path, matcher, page \\ 1) do
    with {:ok, response} <- request(client, :get, path.(page), nil),
         {:ok, comments} <- comments(response) do
      case find_comment(comments, matcher) do
        {:ok, id} ->
          {:ok, id}

        :not_found when length(comments) < @page_size ->
          :not_found

        :not_found when page < @maximum_pages ->
          find_comments(client, path, matcher, page + 1)

        :not_found ->
          {:error, {:github_reconciliation_incomplete, @maximum_pages * @page_size}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp find_comment(comments, matcher) do
    Enum.reduce_while(comments, :not_found, fn comment, :not_found ->
      case matcher.(comment) do
        :not_found -> {:cont, :not_found}
        result -> {:halt, result}
      end
    end)
  end

  defp marker_match(%{"body" => body, "id" => id}, marker) when is_binary(body) do
    if String.contains?(body, marker), do: valid_comment_id(id), else: :not_found
  end

  defp marker_match(%{}, _marker), do: :not_found
  defp marker_match(_comment, _marker), do: {:error, {:github_protocol_error, :comment}}

  defp review_marker_match(%{"in_reply_to_id" => root_id} = comment, root_id, marker),
    do: marker_match(comment, marker)

  defp review_marker_match(%{}, _root_id, _marker), do: :not_found

  defp review_marker_match(_comment, _root_id, _marker),
    do: {:error, {:github_protocol_error, :comment}}

  defp comments(%{body: body, status: 200}) when is_list(body), do: {:ok, body}
  defp comments(%{status: 200}), do: {:error, {:github_protocol_error, :comments}}
  defp comments(response), do: api_error(response)

  defp created_comment(%{body: %{"id" => id}, status: 201}), do: valid_comment_id(id)
  defp created_comment(%{status: 201}), do: {:error, {:github_protocol_error, :comment}}
  defp created_comment(response), do: api_error(response)

  defp created_review(%{body: %{"body" => body, "id" => id}, status: 201})
       when is_binary(body),
       do: valid_comment_id(id)

  defp created_review(%{status: 201}), do: {:error, {:github_protocol_error, :pull_review}}
  defp created_review(response), do: api_error(response)

  defp update_comment(client, repository, comment_id, body, path) do
    with :ok <- repository(repository),
         :ok <- positive_id(comment_id),
         :ok <- text(body),
         {:ok, response} <- request(client, :patch, path, %{"body" => body}) do
      case response do
        %{body: %{"id" => ^comment_id}, status: 200} -> :ok
        %{status: 200} -> {:error, {:github_protocol_error, :comment}}
        other -> api_error(other)
      end
    end
  end

  defp reaction(client, repository, comment_id, emoji_name, path) do
    with :ok <- target(repository, comment_id),
         :ok <- text(emoji_name),
         {:ok, response} <- request(client, :post, path, %{"content" => emoji_name}) do
      case response do
        %{status: status} when status in [200, 201] -> :ok
        other -> api_error(other)
      end
    end
  end

  defp check_runs(client, repository, sha, page \\ 1, accumulated \\ []) do
    path =
      "/repos/#{repository}/commits/#{sha}/check-runs?per_page=#{@page_size}&page=#{page}"

    with {:ok, response} <- request(client, :get, path, nil),
         {:ok, runs, total} <- check_run_page(response),
         values <- accumulated ++ runs do
      cond do
        length(values) >= total -> {:ok, Enum.take(values, total)}
        length(runs) < @page_size -> {:error, {:github_protocol_error, :check_runs_count}}
        page >= @maximum_pages -> {:error, {:github_reconciliation_incomplete, :check_runs}}
        true -> check_runs(client, repository, sha, page + 1, values)
      end
    end
  end

  defp check_run_page(%{
         body: %{"check_runs" => runs, "total_count" => total},
         status: 200
       })
       when is_list(runs) and is_integer(total) and total >= 0 do
    if Enum.all?(runs, &valid_check_run?/1),
      do: {:ok, runs, total},
      else: {:error, {:github_protocol_error, :check_runs}}
  end

  defp check_run_page(%{status: 200}), do: {:error, {:github_protocol_error, :check_runs}}
  defp check_run_page(response), do: api_error(response)

  defp valid_check_run?(%{"conclusion" => conclusion, "status" => status}) do
    status in ~w(queued in_progress completed pending requested waiting) and
      (is_nil(conclusion) or
         conclusion in ~w(success neutral skipped failure cancelled timed_out action_required stale startup_failure))
  end

  defp valid_check_run?(_run), do: false

  defp commit_statuses(client, repository, sha) do
    path = "/repos/#{repository}/commits/#{sha}/status?per_page=#{@page_size}"

    with {:ok, response} <- request(client, :get, path, nil) do
      commit_status_response(response)
    end
  end

  defp commit_status_response(%{body: %{"statuses" => statuses}, status: 200})
       when is_list(statuses) do
    if Enum.all?(statuses, &valid_commit_status?/1),
      do: {:ok, statuses},
      else: {:error, {:github_protocol_error, :commit_statuses}}
  end

  defp commit_status_response(%{status: 200}),
    do: {:error, {:github_protocol_error, :commit_statuses}}

  defp commit_status_response(response), do: api_error(response)

  defp valid_commit_status?(%{"state" => state}),
    do: state in ~w(error failure pending success)

  defp valid_commit_status?(_status), do: false

  defp summarize_checks(check_runs, statuses) do
    outcomes = Enum.map(check_runs, &check_run_outcome/1) ++ Enum.map(statuses, &status_outcome/1)
    total = length(outcomes)
    failed = Enum.count(outcomes, &(&1 == :failed))
    passed = Enum.count(outcomes, &(&1 == :passed))

    state =
      cond do
        total == 0 -> "none"
        failed > 0 -> "failing"
        passed == total -> "passing"
        true -> "pending"
      end

    %{failed: failed, passed: passed, state: state, total: total}
  end

  defp check_run_outcome(%{"status" => "completed", "conclusion" => conclusion})
       when conclusion in ~w(success neutral skipped),
       do: :passed

  defp check_run_outcome(%{"status" => "completed"}), do: :failed
  defp check_run_outcome(_run), do: :pending

  defp status_outcome(%{"state" => "success"}), do: :passed
  defp status_outcome(%{"state" => state}) when state in ~w(error failure), do: :failed
  defp status_outcome(_status), do: :pending

  defp valid_comment_id(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp valid_comment_id(_id), do: {:error, {:github_protocol_error, :comment}}

  defp api_error(%{body: body, headers: headers, status: status})
       when status in [403, 429] and is_list(headers) do
    error = {:github_api_error, status, body}

    if status == 429 or github_rate_limited?(body, headers),
      do: {:error, {:delivery_rate_limited, rate_limit_delay(headers), error}},
      else: {:error, error}
  end

  defp api_error(%{body: body, status: status}) when is_integer(status),
    do: {:error, {:github_api_error, status, body}}

  defp api_error(_response), do: {:error, {:github_protocol_error, :response}}

  defp request(%__MODULE__{http: http, requester: requester}, method, path, document),
    do: requester.request(http, method, path, document, @headers)

  defp pull_request(
         %{
           "base" => %{"ref" => base_ref},
           "draft" => draft,
           "head" => %{"ref" => head_ref, "sha" => head_sha},
           "html_url" => url,
           "merged" => merged,
           "number" => number,
           "state" => state
         } = pull
       ) do
    with true <- is_integer(number) and number > 0,
         true <- is_boolean(draft) and is_boolean(merged),
         true <- state in ["open", "closed"],
         :ok <- ref_component(base_ref),
         :ok <- ref_component(head_ref),
         true <- git_identity?(head_sha),
         true <- github_pull_url?(url) do
      with {:ok, merge_sha, merged_at} <- merge_identity(pull) do
        {:ok,
         %{
           "base_ref" => base_ref,
           "draft" => draft,
           "head_ref" => head_ref,
           "head_sha" => head_sha,
           "merge_sha" => merge_sha,
           "merged" => merged,
           "merged_at" => merged_at,
           "number" => number,
           "state" => state,
           "url" => url
         }}
      end
    else
      false -> {:error, {:github_protocol_error, :pull_request}}
      {:error, _reason} -> {:error, {:github_protocol_error, :pull_request}}
    end
  end

  defp pull_request(_pull), do: {:error, {:github_protocol_error, :pull_request}}

  defp merge_identity(%{"merged" => true} = pull) do
    sha = pull["merge_commit_sha"]

    with true <- git_identity?(sha),
         {:ok, merged_at} <- github_datetime(pull["merged_at"]) do
      {:ok, sha, DateTime.to_iso8601(merged_at)}
    else
      _invalid -> {:error, {:github_protocol_error, :pull_request}}
    end
  end

  defp merge_identity(%{"merged" => false}), do: {:ok, nil, nil}

  defp github_datetime(value) do
    case DateTime.from_iso8601(value || "") do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, :datetime}
    end
  end

  defp target(repository, id) do
    with true <- is_binary(repository) and Regex.match?(@repository, repository),
         :ok <- positive_id(id) do
      :ok
    else
      _invalid -> {:error, {:invalid_github_api_request, :target}}
    end
  end

  defp repository(value) do
    if is_binary(value) and Regex.match?(@repository, value),
      do: :ok,
      else: {:error, {:invalid_github_api_request, :repository}}
  end

  defp ref_component(value) do
    valid =
      is_binary(value) and byte_size(value) in 1..240 and
        not String.starts_with?(value, ["-", "/"]) and
        not String.ends_with?(value, ["/", "."]) and
        not String.contains?(value, [
          "..",
          "@{",
          " ",
          "~",
          "^",
          ":",
          "?",
          "*",
          "[",
          "\\",
          "\r",
          "\n",
          "\t"
        ])

    if valid, do: :ok, else: {:error, {:invalid_github_api_request, :ref}}
  end

  defp git_identity?(value),
    do: is_binary(value) and Regex.match?(~r/\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/, value)

  defp github_pull_url?(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: "github.com", path: path}} ->
        is_binary(path) and
          Regex.match?(~r/\A\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*\z/, path)

      _invalid ->
        false
    end
  end

  defp github_pull_url?(_value), do: false

  defp positive_id(value) when is_integer(value) and value > 0, do: :ok
  defp positive_id(_value), do: {:error, {:invalid_github_api_request, :target}}

  defp text(value) do
    if is_binary(value) and String.valid?(value) and byte_size(value) > 0 and
         byte_size(value) <= 256 * 1_024,
       do: :ok,
       else: {:error, {:invalid_github_api_request, :text}}
  end

  defp normalize_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      normalize_attributes(Map.new(attributes))
    else
      {:error, {:invalid_github_client, :fields}}
    end
  end

  defp normalize_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_github_client, :fields}}
  end

  defp normalize_attributes(_attributes), do: {:error, {:invalid_github_client, :fields}}

  defp requester?(requester) do
    is_atom(requester) and Code.ensure_loaded?(requester) and
      function_exported?(requester, :request, 5)
  end

  defp github_rate_limited?(body, headers) do
    not is_nil(header(headers, "retry-after")) or header(headers, "x-ratelimit-remaining") == "0" or
      rate_limit_message?(body)
  end

  defp rate_limit_message?(%{"message" => message}) when is_binary(message),
    do: message |> String.downcase() |> String.contains?("rate limit")

  defp rate_limit_message?(_body), do: false

  defp rate_limit_delay(headers) do
    retry_after(header(headers, "retry-after")) ||
      reset_after(header(headers, "x-ratelimit-reset"), System.system_time(:second)) ||
      @default_rate_limit_delay_seconds
  end

  defp retry_after(value) do
    case Integer.parse(value || "") do
      {seconds, ""} when seconds > 0 -> seconds
      _invalid -> nil
    end
  end

  defp reset_after(value, now) do
    case Integer.parse(value || "") do
      {reset_at, ""} when reset_at > now -> reset_at - now
      _invalid -> nil
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn
      {header_name, value} when is_binary(header_name) and is_binary(value) ->
        if String.downcase(header_name) == name, do: value

      _invalid ->
        nil
    end)
  end
end
