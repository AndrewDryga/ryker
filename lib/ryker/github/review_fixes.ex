defmodule Ryker.GitHub.ReviewFixes do
  @moduledoc "Publication proof and current writer authority for resolving selected review findings."
  alias Ryker.GitHub
  alias Ryker.Maps
  alias Ryker.Publication
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Work

  def resolve(binding, arguments, configured) do
    with true <- Maps.exact_keys?(arguments, ~w(thread_id verification)),
         verification when is_binary(verification) and byte_size(verification) in 1..4000 <-
           arguments["verification"],
         true <- String.trim(verification) != "",
         {:ok, %{} = target} <- Work.PublicationTarget.parse(binding.session.publication_target),
         %{} = finding <-
           Enum.find(target["findings"], &(&1["thread_id"] == arguments["thread_id"])),
         {:ok, publication} <- published(binding.session.id),
         true <- publication.review_document["parent_head"] == target["head_commit"],
         true <- publication.review_document["gate"] == "passed",
         :ok <- current_access(target, configured),
         {:ok, receipt} <-
           GitHub.Client.ReviewThreads.resolve(
             configured.review_client,
             target,
             finding,
             publication.commit_sha
           ) do
      {:ok, Map.put(receipt, "verification", verification)}
    else
      {:error, reason} -> {:error, reason}
      _unproven -> {:error, :review_fix_not_verified}
    end
  end

  defp published(session_id) do
    query =
      session_id
      |> Publication.Publication.Query.by_session_id()
      |> Publication.Publication.Query.published()
      |> Publication.Publication.Query.limit_to(2)

    case Repo.all(query) do
      [publication] -> {:ok, publication}
      _unpublished -> {:error, :review_fix_not_published}
    end
  end

  defp current_access(target, configured) do
    with {:ok, snapshot} <- Settings.fetch(),
         true <- snapshot.github.enabled,
         %{} = saved <- Enum.find(snapshot.github_bindings, &(&1.name == target["binding_ref"])),
         true <-
           saved.repository_ref == target["repository_ref"] and
             saved.repository_id == target["repository_id"] and
             saved.installation_id == target["installation_id"] and
             saved.ryker_actor_id == target["app_actor_id"],
         %{github_access: :available} = repository <-
           Enum.find(snapshot.repositories, &(&1.ref == target["repository_ref"])),
         true <-
           repository.github_repository == configured.repository_full_name and
             configured.repository_id == saved.repository_id,
         {:ok, trusted} <-
           GitHub.Binding.new(%{
             name: saved.name,
             repository_full_name: repository.github_repository,
             repository_id: saved.repository_id,
             installation_id: saved.installation_id,
             ryker_actor_id: saved.ryker_actor_id
           }),
         actor <- target["authorization"],
         :ok <-
           GitHub.RepositoryAccess.authorize(
             trusted,
             %{"sender" => %{"id" => actor["id"], "login" => actor["login"], "type" => "User"}},
             configured.review_client.http,
             requester: configured.review_client.requester,
             expected_actor_id: actor["id"]
           ),
         do: :ok,
         else: (_unproven -> {:error, :actor_not_authorized})
  end
end
