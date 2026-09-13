defmodule Ryker.Settings.WorkerPolicies do
  @moduledoc """
  What the enrolled fleet advertises, and whether a saved binding still matches it.

  A policy digest is execution evidence, so it is copied from an authenticated
  worker advertisement rather than typed into a form. A binding whose policy the
  fleet no longer advertises becomes unavailable: it is never silently repointed
  at a different digest, never resolved to a policy with more authority, and
  never dropped, because the pin an active session already carries has to stay
  readable. Revoking a worker withdraws exactly the advertisements it made.

  The worker protocol advertises policy names, digests, authority digests,
  repositories, capabilities and capacity. It does not advertise a model or an
  effort, so nothing here infers one from a policy name.
  """

  import Ecto.Query

  alias Ryker.CoopFleet.Worker
  alias Ryker.Repo

  @type advertisement :: %{
          authority_digest: String.t() | nil,
          digest: String.t(),
          name: String.t(),
          workers: [String.t()],
          workspace_ref: String.t()
        }

  @type catalog :: %{
          policies: [advertisement()],
          repositories: [String.t()],
          capabilities: [String.t()],
          workspaces: [%{ref: String.t(), workers: pos_integer(), eligible: non_neg_integer()}]
        }

  @doc """
  The current advertisements, optionally limited to the selected workspace.

  A revoked worker advertises nothing: its grant was withdrawn explicitly and
  continuing to offer its policies would be the fallback this module exists to
  prevent.
  """
  @spec catalog(String.t() | nil) :: catalog()
  def catalog(workspace_ref \\ nil) do
    workers =
      Repo.all(
        from(worker in Worker, where: worker.state != :revoked and is_nil(worker.revoked_at))
      )

    selected =
      case workspace_ref do
        ref when is_binary(ref) -> Enum.filter(workers, &(&1.workspace_ref == ref))
        nil -> workers
      end

    %{
      capabilities: values(selected, & &1.capabilities, "name"),
      policies: policies(selected),
      repositories: values(selected, & &1.repositories, "ref"),
      workspaces: workspaces(workers)
    }
  end

  @doc """
  Fills a policy binding's digests from the advertisement of the named policy.

  The form chooses a name; this chooses nothing. Two workers advertising the
  same name with different digests is an ambiguity, not a majority vote.
  """
  @spec resolve(map(), String.t() | nil) ::
          {:ok, map()} | {:error, :policy_unavailable | :policy_ambiguous}
  def resolve(attributes, workspace_ref) do
    name = Map.get(attributes, :policy_name)

    case Enum.filter(catalog(workspace_ref).policies, &(&1.name == name)) do
      [] ->
        {:error, :policy_unavailable}

      [advertisement] ->
        {:ok,
         attributes
         |> Map.put(:policy_digest, advertisement.digest)
         |> Map.put(:authority_digest, advertisement.authority_digest)
         |> Map.put(:verified_by, :worker)
         |> Map.put(:verified_worker_ref, List.first(advertisement.workers))}

      _conflicting ->
        {:error, :policy_ambiguous}
    end
  end

  @doc "Whether one saved binding still matches what the fleet advertises."
  @spec binding_status(struct(), map()) :: %{label: String.t(), tone: String.t()}
  def binding_status(binding, %{workers: catalog}) do
    case Enum.find(catalog.policies, &(&1.name == binding.policy_name)) do
      nil -> unadvertised(binding)
      %{digest: digest} when digest != binding.policy_digest -> changed()
      advertisement -> verified(advertisement)
    end
  end

  defp verified(%{workers: workers}) do
    %{
      label: "advertised by #{length(workers)} #{worker_noun(length(workers))}",
      tone: "verified"
    }
  end

  defp changed do
    %{
      label: "the fleet advertises a different revision; the pinned one still runs",
      tone: "changed"
    }
  end

  defp unadvertised(%{verified_by: :import}) do
    %{label: "imported, not yet confirmed by a worker", tone: "unavailable"}
  end

  defp unadvertised(_binding) do
    %{label: "no enrolled worker advertises this policy", tone: "unavailable"}
  end

  defp worker_noun(1), do: "worker"
  defp worker_noun(_count), do: "workers"

  defp policies(workers) do
    workers
    |> Enum.flat_map(fn worker ->
      Enum.map(worker.policy_digests, fn {name, digest} ->
        %{
          authority_digest: Map.get(worker.policy_authority_digests, name),
          digest: digest,
          name: name,
          worker_ref: worker.id,
          workspace_ref: worker.workspace_ref
        }
      end)
    end)
    |> Enum.group_by(&{&1.name, &1.digest, &1.authority_digest, &1.workspace_ref})
    |> Enum.map(fn {{name, digest, authority_digest, workspace_ref}, advertisements} ->
      %{
        authority_digest: authority_digest,
        digest: digest,
        name: name,
        workers: advertisements |> Enum.map(& &1.worker_ref) |> Enum.sort(),
        workspace_ref: workspace_ref
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp workspaces(workers) do
    workers
    |> Enum.group_by(& &1.workspace_ref)
    |> Enum.map(fn {ref, workspace_workers} ->
      %{
        eligible: Enum.count(workspace_workers, &(&1.state == :eligible)),
        ref: ref,
        workers: length(workspace_workers)
      }
    end)
    |> Enum.sort_by(& &1.ref)
  end

  defp values(workers, read, key) do
    workers
    |> Enum.flat_map(fn worker ->
      worker |> read.() |> Enum.flat_map(&List.wrap(Map.get(&1, key)))
    end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
