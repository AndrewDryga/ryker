defmodule Ryker.GitHubActions do
  @moduledoc "Repository-scoped GitHub sign-in and human action requests."
  alias Ryker.CanonicalJSON
  alias Ryker.Config
  alias Ryker.Credentials
  alias Ryker.Delivery
  alias Ryker.GitHub
  alias Ryker.GitHubActions.IssueWorkflows
  alias Ryker.GitHubActions.Requests
  alias Ryker.Repo
  alias Ryker.Settings

  @maximum_selected_findings 20

  def maximum_selected_findings, do: @maximum_selected_findings

  @doc "The exact callback to register on the connected GitHub App."
  @spec callback_url() :: String.t()
  def callback_url do
    base = Config.fetch_env!(:control_public_url)
    String.trim_trailing(base, "/") <> "/github/actions/callback"
  end

  @doc "Starts repository sign-in without creating an operator session."
  @spec begin_sign_in(String.t(), integer()) :: {:ok, String.t(), map()} | {:error, term()}
  def begin_sign_in(return_path, now) do
    with :ok <- return_path(return_path),
         {:ok, config} <- configuration() do
      {url, challenge} = GitHub.OAuth.begin(config, return_path, now)
      {:ok, url, challenge}
    end
  end

  @doc "Exchanges a callback bound to the initiating browser."
  @spec finish_sign_in(map(), map(), integer(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def finish_sign_in(challenge, params, now, options \\ []) do
    with {:ok, config} <- configuration(),
         do: GitHub.OAuth.finish(config, challenge, params, now, options)
  end

  @doc "Rechecks the signed-in user and their current access to the exact installed repository."
  @spec authorize(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def authorize(name, token, options \\ []), do: authorize_access(name, token, options, "push")

  @doc "Rechecks repository Read access for protected results; it grants no action."
  def authorize_read(name, token, options \\ []),
    do: authorize_access(name, token, options, "pull")

  @doc "Whether the connected App can serve protected repository action pages."
  def available?, do: match?({:ok, _configuration}, configuration())

  defp authorize_access(name, token, options, permission) do
    with {:ok, snapshot} <- Settings.fetch(),
         true <- snapshot.github.enabled,
         %{} = binding <- Enum.find(snapshot.github_bindings, &(&1.name == name)),
         %{github_access: :available} = repository <-
           Enum.find(snapshot.repositories, &(&1.ref == binding.repository_ref)),
         {:ok, http} <- user_client(snapshot.github.api_url, token, options),
         {:ok, %{"id" => actor_id, "login" => login, "type" => "User"} = actor} <-
           read(http, "/user", options),
         true <- GitHub.id?(actor_id) and GitHub.login?(login),
         {:ok, %{"id" => repository_id, "permissions" => permissions}} <-
           read(http, "/repos/" <> repository.github_repository, options),
         true <- repository_id == binding.repository_id and permissions[permission] == true do
      {:ok,
       %{
         actor: Map.take(actor, ~w(id login type)),
         binding: binding,
         repository: repository,
         http: http,
         settings: snapshot
       }}
    else
      _refused -> {:error, :repository_access_required}
    end
  end

  @doc "The current review checklist, after checking the viewer's repository access."
  def review(name, token, number, options \\ []) do
    with {:ok, access} <- authorize(name, token, options),
         {:ok, review} <- GitHub.ReviewFindings.fetch(access, number, options) do
      {:ok, Map.put(review, :snapshot, GitHub.ReviewFindings.snapshot(review))}
    end
  end

  @doc "Queues only the selected versions of current review findings."
  def fix_review(name, token, number, expected, selected, options \\ []) do
    with {:ok, access} <- authorize(name, token, options),
         :ok <- selected_ids(selected) do
      key = CanonicalJSON.digest(%{"snapshot" => expected, "selection" => Enum.sort(selected)})

      result =
        case Requests.fetch(access, number, "fix_review", key) do
          {:ok, receipt} ->
            {:ok, receipt}

          {:error, :not_found} ->
            start_review_fix(access, number, expected, selected, key, options)
        end

      with {:ok, receipt} <- result do
        url =
          "#{GitHub.web_url(access.settings.github.api_url)}/#{access.repository.github_repository}/pull/#{number}"

        {:ok, Map.put(receipt, :url, url)}
      end
    end
  end

  @doc "An authenticated new-issue webhook may show configured controls; it grants no task start."
  def offer_issue_actions(binding, "issues", %{"action" => action, "issue" => issue} = payload)
      when action in ["opened", "reopened"] do
    with :ok <- GitHub.Binding.authorize_payload(binding, payload),
         {:ok, _config} <- configuration(),
         {:ok, settings} <- Settings.fetch(),
         saved when not is_nil(saved) <-
           Enum.find(settings.github_bindings, &(&1.name == binding.name)),
         %{github_issue_actions: true, github_access: :available} = repository <-
           Enum.find(settings.repositories, &(&1.ref == saved.repository_ref)),
         true <-
           saved.repository_id == binding.repository_id and
             saved.installation_id == binding.installation_id,
         access <- %{settings: settings, repository: repository, binding: saved},
         {:ok, snapshot} <- GitHub.IssueSnapshot.prepare(access, issue["number"], issue) do
      case IssueWorkflows.ensure(access, snapshot) do
        {:ok, _workflow} ->
          :ok

        {:error, reason} when reason in [:repository_access_changed, :issue_actions_disabled] ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    else
      _disabled_or_unavailable -> :ok
    end
  end

  def offer_issue_actions(_binding, _event, _payload), do: :ok

  @doc "Offers native plan/build links in the bound issue without granting a build."
  def offer_issue_controls(binding, %{subject_kind: "issue", number: number}, configured) do
    with {:ok, _config} <- configuration(),
         {:ok, settings} <- Settings.fetch(),
         saved when not is_nil(saved) <-
           Enum.find(settings.github_bindings, fn saved ->
             binding.episode.destination_conversation_ref ==
               "github:#{saved.name}:repository:#{saved.repository_id}"
           end),
         true <- saved.repository_id == configured.repository_id,
         %{github_access: :available} = repository <-
           Enum.find(settings.repositories, &(&1.ref == saved.repository_ref)),
         %{http: http, requester: requester} <- configured.client,
         access <- %{settings: settings, repository: repository, binding: saved, http: http},
         {:ok, issue} <- GitHub.IssueSnapshot.fetch(access, number, requester: requester),
         {:ok, workflow} <- IssueWorkflows.offer(binding, access, issue) do
      {:ok,
       %{
         "status" => "controls_queued",
         "url" => issue_action_url(workflow.binding_ref, workflow.number)
       }}
    else
      _refused -> {:error, :issue_actions_unavailable}
    end
  end

  def offer_issue_controls(_binding, _target, _configured), do: {:error, :issue_required}

  defp issue_action_url(binding, number) do
    String.trim_trailing(Config.fetch_env!(:control_public_url), "/") <>
      "/github/actions/issue/#{binding}/#{number}"
  end

  @doc "The current issue and saved plan versions, for a signed-in repository writer."
  def issue(name, token, number, options \\ []) do
    with {:ok, access} <- authorize(name, token, options),
         {:ok, issue} <- GitHub.IssueSnapshot.fetch(access, number, options) do
      {:ok,
       Map.put(
         IssueWorkflows.view(access, issue, Keyword.get(options, :history_before)),
         :binding,
         name
       )}
    end
  end

  @doc "Accepts an explicit plan or build request for the signed page's exact version."
  def start_issue(name, token, number, kind, expected, options \\ []) do
    with {:ok, access} <- authorize(name, token, options),
         {:ok, issue} <- GitHub.IssueSnapshot.fetch(access, number, options),
         do: IssueWorkflows.start(access, issue, kind, expected)
  end

  @doc "Saves a human's edit as a new plan version without starting code changes."
  def edit_issue_plan(name, token, number, expected, body, options \\ []) do
    with {:ok, access} <- authorize(name, token, options),
         {:ok, issue} <- GitHub.IssueSnapshot.fetch(access, number, options),
         do: IssueWorkflows.edit(access, issue, expected, body)
  end

  @doc "A delivered engineering brief, visible only to its repository's writers."
  def engineering_offer(ref, token, options \\ []) do
    with {:ok, offer} <- GitHub.Confirmations.engineering_offer(ref),
         {:ok, access} <- authorize(offer.binding, token, options),
         true <- offer.repository_id == access.binding.repository_id,
         true <- offer.record.payload["repository"] == access.repository.ref do
      {:ok, %{offer: offer, access: access}}
    else
      _unavailable -> {:error, :offer_unavailable}
    end
  end

  @doc "Starts the reviewed engineering offer once, after a fresh repository permission check."
  def confirm_engineering_offer(ref, token, expected, options \\ []) do
    with {:ok, %{access: access}} <- engineering_offer(ref, token, options) do
      Repo.transaction(fn -> confirm_offer_locked(ref, expected, access) end)
    end
  end

  defp confirm_offer_locked(ref, expected, access) do
    :ok = Settings.synchronize_in_transaction()
    current = Settings.fetch!()

    if GitHub.TaskAccess.authority_configuration(current) !=
         GitHub.TaskAccess.authority_configuration(access.settings),
       do: Repo.rollback(:repository_access_changed)

    runtime = Config.get_env(:github) || %{}

    case GitHub.Confirmations.confirm_engineering(
           ref,
           expected,
           "github-user:#{access.actor["id"]}",
           access,
           get_in(runtime, [:server, :confirmations])
         ) do
      {:ok, result} -> result
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp start_review_fix(access, number, expected, selected, key, options) do
    with {:ok, review} <- GitHub.ReviewFindings.fetch(access, number, options),
         {:ok, findings} <- GitHub.ReviewFindings.select(review, expected, selected) do
      evidence = %{
        "head" => review.pull["headRefOid"],
        "app_actor_id" => review.app_actor_id,
        "branch" => review.pull["headRefName"],
        "base_branch" => review.pull["baseRefName"],
        "pull_request_number" => number,
        "findings" => findings,
        "snapshot" => expected,
        "request_key" => key
      }

      request =
        "Fix the selected review findings on this existing pull request. " <>
          "Use the exact findings in action_evidence. Preserve other work. " <>
          "Do not merge or approve the PR. Report which findings were fixed and how they were tested. " <>
          "After publication succeeds, use resolve_github_review_finding only for selected findings you fixed and checked. Leave uncertain or unfinished findings open and explain them."

      Requests.record(access, number, "fix_review", request, evidence)
    end
  end

  defp selected_ids([]), do: {:error, :empty_selection}

  defp selected_ids(ids) when is_list(ids) and length(ids) > @maximum_selected_findings,
    do: {:error, :too_many_findings}

  defp selected_ids(ids) when is_list(ids) do
    if Enum.uniq(ids) == ids and Enum.all?(ids, &(is_binary(&1) and byte_size(&1) in 1..256)),
      do: :ok,
      else: {:error, :invalid_selection}
  end

  defp selected_ids(_ids), do: {:error, :invalid_selection}

  defp configuration do
    case Settings.fetch() do
      {:ok, %{github: %{enabled: true} = github}} -> client_configuration(github)
      _missing -> {:error, :github_sign_in_not_configured}
    end
  end

  @doc "Whether the saved App has usable local sign-in credentials, including before adding its first repository."
  @spec sign_in_configured?(map()) :: boolean()
  def sign_in_configured?(github), do: match?({:ok, _}, client_configuration(github))

  defp client_configuration(%{oauth_client_id: client_id, api_url: api_url}) do
    with true <- is_binary(client_id) and client_id != "",
         base when is_binary(base) <- Config.get_env(:control_public_url),
         true <- URI.parse(base).scheme in ["http", "https"],
         {:ok, secret} <- Credentials.fetch(:github_oauth_secret, "primary") do
      {:ok,
       %{
         client_id: client_id,
         client_secret: secret,
         callback_url: callback_url(),
         web_url: GitHub.web_url(api_url)
       }}
    else
      _missing -> {:error, :github_sign_in_not_configured}
    end
  end

  defp user_client(api_url, token, options)
       when is_binary(token) and byte_size(token) in 8..4096 do
    Delivery.JSONClient.new(%{
      base_url: api_url,
      finch: Keyword.get(options, :finch, Ryker.CoopFinch),
      receive_timeout: 15_000,
      token_provider: fn -> {:ok, token} end
    })
  end

  defp user_client(_api_url, _token, _options), do: {:error, :sign_in_required}

  defp read(http, path, options) do
    requester = Keyword.get(options, :requester, Delivery.JSONClient)
    headers = [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]

    case requester.request(http, :get, path, nil, headers) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      _unavailable -> {:error, :github_unavailable}
    end
  end

  defp return_path("/github/actions/" <> rest) do
    if byte_size(rest) in 1..1024 and not String.contains?(rest, ["\\", "\r", "\n", "?"]),
      do: :ok,
      else: {:error, :invalid_action_link}
  end

  defp return_path(_path), do: {:error, :invalid_action_link}
end
