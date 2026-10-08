defmodule Ryker.Ingress.WorkProfile do
  @moduledoc """
  Host-owned execution placement frozen beside one ingress occurrence.

  Source payloads never construct this value. An authenticated adapter or
  trusted route binds the Coop policies and the environment before the input
  enters durable admission custody.

  Work in an environment with repositories mounts all of them and may change
  its read and write ones. The profile names every repository
  (`repositories`, the default first) and keeps the policies per work class
  of each one work may change (`policies`); a repository without policies of
  its own is read only: it is only ever mounted read-only beside the one work
  changes, never as the working copy. The default is always one work may
  change. Which repository a piece of work changes is chosen per task among
  those: `policy_for/3` returns the policy for the chosen repository and the
  repository context its session mounts, the chosen one as the working copy
  and every other one read-only. The environment's `parallel_goal_limit` and
  optional Emisar account travel with it.

  `policy`, `policy_digest`, `authority_digest` and `repository_ref` are the
  default placement: in an environment with repositories they are derived from
  its first repository and never given separately. An environment without
  repositories runs on one set of class policies and mounts nothing. Work
  outside any environment keeps its single-repository or bare shape: it names
  no environment, no repository set and no Emisar account, and its document
  carries none of those keys.
  """
  alias Ryker.Crypto
  alias Ryker.Maps
  alias Ryker.Reference
  alias Ryker.Work

  @work_classes [:conversational, :standard, :deep]
  @base_fields [:policy, :policy_digest, :repository_ref]
  @placement_fields [
    :emisar_connection_ref,
    :environment_ref,
    :parallel_goal_limit,
    :policies,
    :repositories
  ]
  @fields @base_fields ++ [:authority_digest, :class_policies | @placement_fields]
  @environment_ref ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
  # Coop mounts at most 32 read-only repositories beside the working copy.
  @maximum_repositories 33
  @enforce_keys @base_fields
  defstruct @base_fields ++
              [
                authority_digest: nil,
                class_policies: nil,
                emisar_connection_ref: nil,
                environment_ref: nil,
                parallel_goal_limit: nil,
                policies: nil,
                repositories: []
              ]

  @type class_policy :: %{
          policy: String.t(),
          policy_digest: String.t(),
          authority_digest: String.t() | nil
        }

  @type t :: %__MODULE__{
          policy: String.t(),
          policy_digest: String.t(),
          authority_digest: String.t() | nil,
          repository_ref: String.t() | nil,
          class_policies: %{required(atom()) => class_policy()} | nil,
          emisar_connection_ref: String.t() | nil,
          environment_ref: String.t() | nil,
          parallel_goal_limit: 1..3 | nil,
          policies: %{required(String.t()) => %{required(atom()) => class_policy()}} | nil,
          repositories: [String.t()]
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- attributes(attributes) do
      if is_nil(attributes.policies),
        do: single(attributes),
        else: environment(attributes)
    end
  end

  @spec prepare(t() | keyword() | map() | nil) :: {:ok, t() | nil} | {:error, term()}
  def prepare(nil), do: {:ok, nil}
  def prepare(%__MODULE__{} = profile), do: profile |> Map.from_struct() |> new()
  def prepare(attributes), do: new(attributes)

  @doc """
  The repositories a routing decision chooses among: those work may change in
  an environment with more than one. With one or none there is nothing to
  choose.
  """
  @spec repository_choices(t()) :: [String.t()]
  def repository_choices(%__MODULE__{} = profile) do
    case repository_refs(profile) do
      [_one, _another | _rest] = repositories -> repositories
      _nothing_to_choose -> []
    end
  end

  @doc """
  Every repository work placed by this profile may change, the default first:
  an environment's read and write repositories, a single repository outside
  any environment, or none.
  """
  @spec repository_refs(t()) :: [String.t()]
  def repository_refs(%__MODULE__{policies: %{} = policies, repositories: repositories}),
    do: Enum.filter(repositories, &Map.has_key?(policies, &1))

  def repository_refs(%__MODULE__{repository_ref: repository_ref}), do: List.wrap(repository_ref)

  @doc "The repositories work placed by this profile only reads: mounted, never changed."
  @spec read_only_refs(t()) :: [String.t()]
  def read_only_refs(%__MODULE__{policies: %{} = policies, repositories: repositories}),
    do: Enum.reject(repositories, &Map.has_key?(policies, &1))

  def read_only_refs(%__MODULE__{}), do: []

  @doc """
  The policy one work class runs under and the workspace its session mounts.

  `repository_ref` chooses which repository of an environment the work
  changes; nil is the default, the first. The chosen repository is the
  session's working copy and every other repository of the environment is
  mounted read-only beside it. A read-only repository cannot be chosen. Work
  outside an environment, or in one without repositories, has exactly one
  placement.
  """
  @spec policy_for(t(), atom(), String.t() | nil) ::
          {:ok,
           %{
             name: String.t(),
             digest: String.t(),
             authority_digest: String.t() | nil,
             environment_ref: String.t() | nil,
             repository_ref: String.t() | nil
           }}
          | {:error, term()}
  def policy_for(profile, work_class, repository_ref \\ nil)

  def policy_for(%__MODULE__{}, work_class, _repository_ref) when work_class not in @work_classes,
    do: {:error, {:invalid_work_profile, :work_class}}

  def policy_for(%__MODULE__{policies: %{} = policies} = profile, work_class, repository_ref) do
    chosen = repository_ref || hd(profile.repositories)

    case Map.fetch(policies, chosen) do
      {:ok, classes} ->
        {:ok,
         classes
         |> Map.fetch!(work_class)
         |> placement(profile.environment_ref, chosen)
         |> Map.put(
           :repository_context,
           Work.RepositoryContext.document(repository_context(profile, chosen))
         )}

      :error ->
        {:error, {:invalid_work_profile, :repository_ref}}
    end
  end

  def policy_for(%__MODULE__{} = profile, work_class, repository_ref)
      when is_nil(repository_ref) or repository_ref == profile.repository_ref do
    selected =
      case profile.class_policies do
        nil ->
          %{
            authority_digest: profile.authority_digest,
            policy: profile.policy,
            policy_digest: profile.policy_digest
          }

        policies ->
          Map.fetch!(policies, work_class)
      end

    {:ok, placement(selected, profile.environment_ref, profile.repository_ref)}
  end

  def policy_for(%__MODULE__{}, _work_class, _repository_ref),
    do: {:error, {:invalid_work_profile, :repository_ref}}

  @spec document(t()) :: map()
  def document(%__MODULE__{policies: %{} = policies} = profile) do
    %{
      "environment_ref" => profile.environment_ref,
      "parallel_goal_limit" => profile.parallel_goal_limit,
      "policies" =>
        Map.new(policies, fn {repository_ref, classes} ->
          {repository_ref, class_policies_document(classes)}
        end),
      "repositories" => profile.repositories
    }
    |> Maps.put_present("emisar_connection_ref", profile.emisar_connection_ref)
  end

  def document(%__MODULE__{} = profile) do
    %{
      "class_policies" => class_policies_document(profile.class_policies),
      "policy" => profile.policy,
      "policy_digest" => profile.policy_digest,
      "repository_ref" => profile.repository_ref
    }
    |> maybe_put_authority_digest(profile.authority_digest)
    |> Maps.put_present("emisar_connection_ref", profile.emisar_connection_ref)
    |> Maps.put_present("environment_ref", profile.environment_ref)
    |> Maps.put_present("parallel_goal_limit", profile.parallel_goal_limit)
  end

  @spec restore(map()) :: {:ok, t()} | {:error, term()}
  def restore(%{"policies" => _policies} = document) do
    keys = Map.keys(document) |> Enum.sort()
    required = ~w(environment_ref parallel_goal_limit policies repositories)

    if Enum.all?(required, &(&1 in keys)) and keys -- ["emisar_connection_ref" | required] == [] do
      new(%{
        emisar_connection_ref: Map.get(document, "emisar_connection_ref"),
        environment_ref: document["environment_ref"],
        parallel_goal_limit: document["parallel_goal_limit"],
        policies: restore_policies(document["policies"]),
        repositories: document["repositories"]
      })
    else
      {:error, {:invalid_work_profile, :fields}}
    end
  end

  def restore(%{} = document) do
    keys = Map.keys(document) |> Enum.sort()
    required = ~w(class_policies policy policy_digest repository_ref)

    allowed =
      ~w(authority_digest emisar_connection_ref environment_ref parallel_goal_limit) ++ required

    if Enum.all?(required, &(&1 in keys)) and keys -- allowed == [] do
      new(%{
        authority_digest: Map.get(document, "authority_digest"),
        class_policies: restore_class_policies(document["class_policies"]),
        emisar_connection_ref: Map.get(document, "emisar_connection_ref"),
        environment_ref: Map.get(document, "environment_ref"),
        parallel_goal_limit: Map.get(document, "parallel_goal_limit"),
        policy: document["policy"],
        policy_digest: document["policy_digest"],
        repository_ref: document["repository_ref"]
      })
    else
      {:error, {:invalid_work_profile, :fields}}
    end
  end

  def restore(_document), do: {:error, {:invalid_work_profile, :fields}}

  # Outside an environment, or in one without repositories: one placement.
  defp single(attributes) do
    with :ok <- reference(attributes.policy, :policy, 1_024),
         :ok <- digest(attributes.policy_digest),
         :ok <- optional_digest(attributes.authority_digest, :authority_digest),
         :ok <- optional_reference(attributes.repository_ref, :repository_ref, 1_024),
         :ok <- no_repository_set(attributes),
         {:ok, class_policies} <- class_policies(attributes.class_policies),
         :ok <- single_placement(attributes),
         :ok <- authority_equivalence(attributes.authority_digest, class_policies) do
      {:ok,
       struct!(
         __MODULE__,
         attributes |> Map.put(:class_policies, class_policies) |> Map.put(:repositories, [])
       )}
    end
  end

  defp no_repository_set(%{repositories: repositories}) when repositories in [nil, []], do: :ok
  defp no_repository_set(_attributes), do: {:error, {:invalid_work_profile, :repositories}}

  # Outside an environment nothing else is placed. An environment without
  # repositories always has its goal limit and optionally an Emisar account,
  # and mounts nothing, so it names no repository.
  defp single_placement(%{environment_ref: nil} = attributes) do
    cond do
      not is_nil(attributes.parallel_goal_limit) ->
        {:error, {:invalid_work_profile, :parallel_goal_limit}}

      not is_nil(attributes.emisar_connection_ref) ->
        {:error, {:invalid_work_profile, :emisar_connection_ref}}

      true ->
        :ok
    end
  end

  defp single_placement(attributes) do
    with :ok <- environment_placement(attributes) do
      if is_nil(attributes.repository_ref),
        do: :ok,
        else: {:error, {:invalid_work_profile, :repository_ref}}
    end
  end

  # An environment with repositories: the class policies of each one work may
  # change, the first repository the default, which work may always change.
  # The default placement is derived, so a caller that also names one must
  # name exactly the derived one.
  defp environment(attributes) do
    with :ok <- environment_repositories(attributes),
         :ok <- environment_placement(attributes),
         {:ok, policies} <- environment_policies(attributes.policies, attributes.repositories),
         :ok <- repository_contexts(attributes),
         {:ok, attributes} <- default_placement(attributes, policies) do
      {:ok, struct!(__MODULE__, attributes)}
    end
  end

  defp environment_repositories(%{environment_ref: nil}),
    do: {:error, {:invalid_work_profile, :repositories}}

  defp environment_repositories(%{repositories: repositories}) do
    if is_list(repositories) and repositories != [] and
         length(repositories) <= @maximum_repositories and
         Enum.uniq(repositories) == repositories and
         Enum.all?(repositories, &(reference(&1, :repository_ref, 1_024) == :ok)),
       do: :ok,
       else: {:error, {:invalid_work_profile, :repositories}}
  end

  defp environment_placement(attributes) do
    cond do
      not (is_binary(attributes.environment_ref) and
               Regex.match?(@environment_ref, attributes.environment_ref)) ->
        {:error, {:invalid_work_profile, :environment_ref}}

      not (is_integer(attributes.parallel_goal_limit) and attributes.parallel_goal_limit in 1..3) ->
        {:error, {:invalid_work_profile, :parallel_goal_limit}}

      optional_reference(attributes.emisar_connection_ref, :emisar_connection_ref, 64) != :ok ->
        {:error, {:invalid_work_profile, :emisar_connection_ref}}

      true ->
        :ok
    end
  end

  # Every repository with policies is one of the environment's, and the
  # default is among them; the others are read only.
  defp environment_policies(%{} = policies, [default | _rest] = repositories) do
    if Map.has_key?(policies, default) and Maps.only_keys?(policies, repositories) do
      prepare_repository_policies(
        policies,
        Enum.filter(repositories, &Map.has_key?(policies, &1))
      )
    else
      {:error, {:invalid_work_profile, :policies}}
    end
  end

  defp environment_policies(_policies, _repositories),
    do: {:error, {:invalid_work_profile, :policies}}

  defp prepare_repository_policies(policies, repositories) do
    Enum.reduce_while(repositories, {:ok, %{}}, fn repository_ref, {:ok, prepared} ->
      case repository_classes(Map.fetch!(policies, repository_ref)) do
        {:ok, classes} -> {:cont, {:ok, Map.put(prepared, repository_ref, classes)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Conversation, standard and deep work in one repository share one
  # execution authority; another repository mounts differently, so its
  # authority differs and is checked on its own.
  defp repository_classes(classes) do
    case class_policies(classes) do
      {:ok, nil} ->
        {:error, {:invalid_work_profile, :policies}}

      {:ok, prepared} ->
        with :ok <- authority_equivalence(prepared.conversational.authority_digest, prepared),
             do: {:ok, prepared}

      {:error, {:invalid_work_profile, :class_policies}} ->
        {:error, {:invalid_work_profile, :policies}}
    end
  end

  defp repository_contexts(attributes) do
    writable = Enum.filter(attributes.repositories, &Map.has_key?(attributes.policies, &1))

    if Enum.all?(writable, fn repository_ref ->
         match?(
           {:ok, _context},
           Work.RepositoryContext.prepare(
             repository_context(attributes, repository_ref),
             repository_ref
           )
         )
       end),
       do: :ok,
       else: {:error, {:invalid_work_profile, :repositories}}
  end

  defp default_placement(attributes, policies) do
    [default | _rest] = attributes.repositories
    conversational = policies |> Map.fetch!(default) |> Map.fetch!(:conversational)

    derived = %{
      authority_digest: conversational.authority_digest,
      policy: conversational.policy,
      policy_digest: conversational.policy_digest,
      repository_ref: default
    }

    mismatch =
      Enum.find([:repository_ref, :policy, :policy_digest, :authority_digest], fn field ->
        given = Map.fetch!(attributes, field)
        not is_nil(given) and given != Map.fetch!(derived, field)
      end)

    cond do
      not is_nil(attributes.class_policies) ->
        {:error, {:invalid_work_profile, :class_policies}}

      mismatch ->
        {:error, {:invalid_work_profile, mismatch}}

      true ->
        {:ok, attributes |> Map.merge(derived) |> Map.put(:policies, policies)}
    end
  end

  defp repository_context(attributes, repository_ref) do
    %{
      context_ref: attributes.environment_ref,
      parallel_goal_limit: attributes.parallel_goal_limit,
      primary_repository: repository_ref,
      read_only_repositories: List.delete(attributes.repositories, repository_ref)
    }
  end

  defp placement(selected, environment_ref, repository_ref) do
    %{
      authority_digest: selected.authority_digest,
      digest: selected.policy_digest,
      environment_ref: environment_ref,
      name: selected.policy,
      repository_ref: repository_ref
    }
  end

  defp attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> attributes(),
       else: {:error, {:invalid_work_profile, :fields}}
  end

  defp attributes(%{} = attributes) do
    keys = Map.keys(attributes) |> Enum.sort()

    required =
      if is_nil(Map.get(attributes, :policies)), do: @base_fields, else: [:policies]

    if Enum.all?(required, &(&1 in keys)) and keys -- @fields == [] do
      {:ok,
       Enum.reduce(@fields, attributes, fn
         :repositories, current -> Map.put_new(current, :repositories, [])
         field, current -> Map.put_new(current, field, nil)
       end)}
    else
      {:error, {:invalid_work_profile, :fields}}
    end
  end

  defp attributes(_attributes), do: {:error, {:invalid_work_profile, :fields}}

  defp digest(value) do
    if Crypto.sha256_hex?(value),
      do: :ok,
      else: {:error, {:invalid_work_profile, :policy_digest}}
  end

  defp optional_digest(nil, _field), do: :ok

  defp optional_digest(value, field) do
    case digest(value) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:invalid_work_profile, field}}
    end
  end

  defp optional_reference(nil, _field, _maximum), do: :ok
  defp optional_reference(value, field, maximum), do: reference(value, field, maximum)

  defp class_policies(nil), do: {:ok, nil}

  defp class_policies(%{} = policies) do
    if Maps.exact_keys?(policies, @work_classes) do
      prepare_class_policies(policies)
    else
      {:error, {:invalid_work_profile, :class_policies}}
    end
  end

  defp class_policies(_policies), do: {:error, {:invalid_work_profile, :class_policies}}

  defp prepare_class_policies(policies) do
    Enum.reduce_while(@work_classes, {:ok, %{}}, fn work_class, {:ok, prepared} ->
      case class_policy(Map.fetch!(policies, work_class)) do
        {:ok, policy} -> {:cont, {:ok, Map.put(prepared, work_class, policy)}}
        {:error, _reason} -> {:halt, {:error, {:invalid_work_profile, :class_policies}}}
      end
    end)
  end

  defp class_policy(%{policy: policy, policy_digest: policy_digest} = attributes)
       when map_size(attributes) in [2, 3] do
    authority_digest = Map.get(attributes, :authority_digest)

    with :ok <- reference(policy, :policy, 1_024),
         :ok <- digest(policy_digest),
         :ok <- optional_digest(authority_digest, :authority_digest) do
      {:ok,
       %{
         authority_digest: authority_digest,
         policy: policy,
         policy_digest: policy_digest
       }}
    end
  end

  defp class_policy(_attributes), do: {:error, :class_policy}

  defp authority_equivalence(nil, nil), do: :ok

  defp authority_equivalence(authority_digest, nil) when is_binary(authority_digest), do: :ok

  # Without an authority digest, distinct class policies cannot be proven to
  # share one execution authority, so only one identity may stand behind them.
  defp authority_equivalence(nil, policies) when is_map(policies) do
    identities =
      policies
      |> Map.values()
      |> Enum.map(&{&1.policy, &1.policy_digest})
      |> Enum.uniq()

    if Enum.all?(policies, fn {_work_class, policy} -> is_nil(policy.authority_digest) end) and
         length(identities) == 1,
       do: :ok,
       else: {:error, {:invalid_work_profile, :authority_equivalence}}
  end

  defp authority_equivalence(authority_digest, policies) when is_map(policies) do
    if is_binary(authority_digest) and
         Enum.all?(policies, fn {_work_class, policy} ->
           policy.authority_digest == authority_digest
         end),
       do: :ok,
       else: {:error, {:invalid_work_profile, :authority_equivalence}}
  end

  defp class_policies_document(nil), do: nil

  defp class_policies_document(policies) do
    Map.new(policies, fn {work_class, policy} ->
      {Atom.to_string(work_class),
       %{"policy" => policy.policy, "policy_digest" => policy.policy_digest}
       |> maybe_put_authority_digest(policy.authority_digest)}
    end)
  end

  defp restore_policies(%{} = policies) do
    Map.new(policies, fn {repository_ref, classes} ->
      {repository_ref, restore_class_policies(classes)}
    end)
  end

  defp restore_policies(value), do: value

  defp restore_class_policies(nil), do: nil

  defp restore_class_policies(%{} = policies) do
    Map.new(policies, fn
      {work_class, %{"policy" => policy, "policy_digest" => policy_digest} = document}
      when work_class in ~w(conversational standard deep) ->
        {String.to_existing_atom(work_class),
         %{
           authority_digest: Map.get(document, "authority_digest"),
           policy: policy,
           policy_digest: policy_digest
         }}

      {work_class, policy} ->
        {work_class, policy}
    end)
  end

  defp restore_class_policies(value), do: value

  defp maybe_put_authority_digest(document, nil), do: document

  defp maybe_put_authority_digest(document, authority_digest),
    do: Map.put(document, "authority_digest", authority_digest)

  defp reference(value, field, maximum),
    do: Reference.check(value, field, :invalid_work_profile, maximum)
end
