defmodule Ryker.Work.PublicationTarget do
  @moduledoc "An immutable publication destination derived from authenticated action ingress."
  alias Ryker.CanonicalJSON
  alias Ryker.GitHub
  alias Ryker.GitObject
  alias Ryker.Ingress
  alias Ryker.Maps
  alias Ryker.Reference
  alias Ryker.Work.RepositorySource

  @fields ~w(kind repository_ref repository_id installation_id app_actor_id binding_ref number head_ref base_ref head_commit source_input_id reason authorization findings)

  @doc "Ordinary instructions have no target; action instructions cannot choose another source."
  def from_input(
        %Ingress.Inbox.Entry{content: %{"event_name" => "ryker_ci_repair"}} = entry,
        repository
      ) do
    with {:ok, target} <- GitHub.CIRepairAuthority.target(entry, repository), do: parse(target)
  end

  def from_input(
        %Ingress.Inbox.Entry{
          content: %{"event_name" => "ryker_action", "payload" => %{"action" => "fix_review"}}
        } = entry,
        repository
      ) do
    with %{
           execution_mode: :live,
           source_kind: "github",
           actor_kind: :user,
           content: %{
             "payload" => %{
               "action" => "fix_review",
               "sender" => actor,
               "repository" => %{"id" => repository_id},
               "installation" => %{"id" => installation_id}
             },
             "action_evidence" => evidence
           }
         } <- entry,
         "github-action:" <> _digest <- entry.event_ref,
         true <- entry.source_item_ref == entry.event_ref,
         true <- entry.actor_ref == "github-user:#{actor["id"]}" do
      parse(%{
        "kind" => "existing_pull_request",
        "repository_ref" => repository,
        "repository_id" => repository_id,
        "installation_id" => installation_id,
        "app_actor_id" => evidence["app_actor_id"],
        "binding_ref" => entry.source_ref,
        "number" => evidence["pull_request_number"],
        "head_ref" => "refs/heads/" <> to_string(evidence["branch"]),
        "base_ref" => "refs/heads/" <> to_string(evidence["base_branch"]),
        "head_commit" => evidence["head"],
        "source_input_id" => entry.id,
        "reason" => "review_fix",
        "authorization" => %{
          "kind" => "github_user",
          "id" => actor["id"],
          "login" => actor["login"]
        },
        "findings" => evidence["findings"]
      })
    else
      _invalid -> {:error, :invalid_publication_target}
    end
  end

  def from_input(
        %Ingress.Inbox.Entry{
          content: %{"event_name" => "ryker_action", "payload" => %{"action" => kind}}
        },
        _repository
      )
      when kind in ["build_issue", "implement_plan"], do: {:ok, nil}

  def from_input(%Ingress.Inbox.Entry{content: %{"event_name" => "ryker_action"}}, _repository),
    do: {:error, :invalid_publication_target}

  def from_input(_entry, _repository), do: {:ok, nil}

  @doc "Validates stored host authority, including its exact field set and byte bound."
  def parse(nil), do: {:ok, nil}

  def parse(%{"kind" => "existing_pull_request"} = target) do
    with true <- Maps.exact_keys?(target, @fields),
         :ok <- authorization(target),
         true <- GitHub.id?(target["repository_id"]) and GitHub.id?(target["installation_id"]),
         true <- GitHub.id?(target["app_actor_id"]),
         true <- GitHub.id?(target["number"]),
         true <-
           Reference.valid?(target["repository_ref"]) and Reference.valid?(target["binding_ref"]),
         true <- GitObject.id?(target["head_commit"]),
         {:ok, _id} <- Ecto.UUID.cast(target["source_input_id"]),
         :ok <- branch(target["head_ref"]),
         :ok <- branch(target["base_ref"]),
         true <- target["head_ref"] != target["base_ref"],
         :ok <- CanonicalJSON.validate(target, max_bytes: 64 * 1024),
         do: {:ok, target},
         else: (_invalid -> {:error, :invalid_publication_target})
  end

  def parse(_target), do: {:error, :invalid_publication_target}

  defp authorization(%{
         "reason" => "review_fix",
         "authorization" => %{"kind" => "github_user", "id" => id, "login" => login} = actor,
         "findings" => findings
       }) do
    with true <- Maps.exact_keys?(actor, ~w(kind id login)),
         true <- GitHub.id?(id) and GitHub.login?(login),
         true <- is_list(findings) and length(findings) in 1..20,
         true <- Enum.all?(findings, &GitHub.ReviewFindings.valid_finding?/1),
         true <- length(Enum.uniq_by(findings, & &1["thread_id"])) == length(findings),
         do: :ok,
         else: (_invalid -> {:error, :invalid_publication_target})
  end

  defp authorization(%{
         "reason" => "automatic_ci_repair",
         "findings" => [],
         "authorization" =>
           %{"kind" => "repository_ci_policy", "repair_id" => repair_id, "round_id" => round_id} =
             authority
       }) do
    with true <- Maps.exact_keys?(authority, ~w(kind repair_id round_id)),
         {:ok, _repair_id} <- Ecto.UUID.cast(repair_id),
         {:ok, _round_id} <- Ecto.UUID.cast(round_id),
         do: :ok,
         else: (_invalid -> {:error, :invalid_publication_target})
  end

  defp authorization(_target), do: {:error, :invalid_publication_target}

  @doc "Pins the task source to the host-authorized head, regardless of a model's selector."
  def pin_source(payload, nil), do: payload

  def pin_source(payload, target) do
    Map.put(payload, "repository_source", %{"kind" => "commit", "sha" => target["head_commit"]})
  end

  defp branch("refs/heads/" <> name) do
    case RepositorySource.parse(%{"kind" => "branch", "name" => name}) do
      {:ok, _source} -> :ok
      _invalid -> {:error, :invalid_publication_target}
    end
  end

  defp branch(_ref), do: {:error, :invalid_publication_target}
end
