defmodule Ryker.Ingress.WorkProfile do
  @moduledoc """
  Host-owned execution placement frozen beside one ingress occurrence.

  Source payloads never construct this value. An authenticated adapter or
  trusted route binds the Coop policies and the environment before the input
  enters durable admission custody.

  Work in an environment changes `repository_ref`, the environment's first
  repository, and only reads `read_only_repository_refs`; the environment's
  `parallel_goal_limit` and optional Emisar account travel with it. A session
  pinned from the profile derives its mounted repository context from exactly
  these fields (`repository_context/1`). Work outside any environment names
  no environment, reads nothing beside its repository and has no Emisar
  account; its document carries none of those keys.
  """

  alias Ryker.Work.RepositoryContext

  @work_classes [:conversational, :standard, :deep]
  @base_fields [:policy, :policy_digest, :repository_ref]
  @placement_fields [
    :emisar_connection_ref,
    :environment_ref,
    :parallel_goal_limit,
    :read_only_repository_refs
  ]
  @fields @base_fields ++ [:authority_digest, :class_policies | @placement_fields]
  @environment_ref ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/
  @enforce_keys @base_fields
  defstruct @base_fields ++
              [
                authority_digest: nil,
                class_policies: nil,
                emisar_connection_ref: nil,
                environment_ref: nil,
                parallel_goal_limit: nil,
                read_only_repository_refs: []
              ]

  @type t :: %__MODULE__{
          policy: String.t(),
          policy_digest: String.t(),
          authority_digest: String.t() | nil,
          repository_ref: String.t() | nil,
          class_policies:
            %{
              required(atom()) => %{
                policy: String.t(),
                policy_digest: String.t(),
                authority_digest: String.t() | nil
              }
            }
            | nil,
          emisar_connection_ref: String.t() | nil,
          environment_ref: String.t() | nil,
          parallel_goal_limit: 1..3 | nil,
          read_only_repository_refs: [String.t()]
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- attributes(attributes),
         :ok <- reference(attributes.policy, :policy, 1_024),
         :ok <- digest(attributes.policy_digest),
         :ok <- optional_digest(attributes.authority_digest, :authority_digest),
         :ok <- optional_reference(attributes.repository_ref, :repository_ref, 1_024),
         {:ok, class_policies} <- class_policies(Map.get(attributes, :class_policies)),
         :ok <- placement(attributes),
         :ok <- authority_equivalence(attributes.authority_digest, class_policies) do
      {:ok, struct!(__MODULE__, Map.put(attributes, :class_policies, class_policies))}
    end
  end

  @spec prepare(t() | keyword() | map() | nil) :: {:ok, t() | nil} | {:error, term()}
  def prepare(nil), do: {:ok, nil}
  def prepare(%__MODULE__{} = profile), do: profile |> Map.from_struct() |> new()
  def prepare(attributes), do: new(attributes)

  @spec policy_for(t(), atom()) ::
          {:ok,
           %{
             name: String.t(),
             digest: String.t(),
             authority_digest: String.t() | nil,
             repository_ref: String.t() | nil
           }}
          | {:error, term()}
  def policy_for(%__MODULE__{} = profile, work_class) when work_class in @work_classes do
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

    policy =
      %{
        digest: selected.policy_digest,
        authority_digest: selected.authority_digest,
        environment_ref: profile.environment_ref,
        name: selected.policy,
        repository_ref: profile.repository_ref
      }
      |> maybe_put_policy_repository_context(repository_context(profile))

    {:ok, policy}
  end

  def policy_for(%__MODULE__{}, _work_class),
    do: {:error, {:invalid_work_profile, :work_class}}

  @doc """
  The workspace a session pinned from this profile mounts: the environment's
  writable repository, the repositories it only reads and its goal limit.
  Work without an environment or without a repository mounts no set.
  """
  @spec repository_context(t()) :: RepositoryContext.t() | nil
  def repository_context(%__MODULE__{environment_ref: nil}), do: nil
  def repository_context(%__MODULE__{repository_ref: nil}), do: nil

  def repository_context(%__MODULE__{} = profile) do
    %{
      context_ref: profile.environment_ref,
      parallel_goal_limit: profile.parallel_goal_limit,
      primary_repository: profile.repository_ref,
      read_only_repositories: profile.read_only_repository_refs
    }
  end

  @spec document(t()) :: map()
  def document(%__MODULE__{} = profile) do
    %{
      "class_policies" => class_policies_document(profile.class_policies),
      "policy" => profile.policy,
      "policy_digest" => profile.policy_digest,
      "repository_ref" => profile.repository_ref
    }
    |> maybe_put_authority_digest(profile.authority_digest)
    |> maybe_put("emisar_connection_ref", profile.emisar_connection_ref)
    |> maybe_put("environment_ref", profile.environment_ref)
    |> maybe_put("parallel_goal_limit", profile.parallel_goal_limit)
    |> maybe_put("read_only_repository_refs", present_list(profile.read_only_repository_refs))
  end

  @spec restore(map()) :: {:ok, t()} | {:error, term()}
  def restore(%{} = document) do
    keys = Map.keys(document) |> Enum.sort()
    required = ~w(class_policies policy policy_digest repository_ref)

    allowed =
      ~w(authority_digest emisar_connection_ref environment_ref parallel_goal_limit read_only_repository_refs) ++
        required

    if Enum.all?(required, &(&1 in keys)) and keys -- allowed == [] do
      new(%{
        authority_digest: Map.get(document, "authority_digest"),
        class_policies: restore_class_policies(document["class_policies"]),
        emisar_connection_ref: Map.get(document, "emisar_connection_ref"),
        environment_ref: Map.get(document, "environment_ref"),
        parallel_goal_limit: Map.get(document, "parallel_goal_limit"),
        policy: document["policy"],
        policy_digest: document["policy_digest"],
        read_only_repository_refs: Map.get(document, "read_only_repository_refs", []),
        repository_ref: document["repository_ref"]
      })
    else
      {:error, {:invalid_work_profile, :fields}}
    end
  end

  def restore(_document), do: {:error, {:invalid_work_profile, :fields}}

  # Outside an environment nothing else is placed. Inside one, the goal limit
  # is always set, the Emisar account is optional, and what is read beside the
  # writable repository must form the bounded set a session can mount.
  defp placement(%{environment_ref: nil} = attributes) do
    cond do
      attributes.read_only_repository_refs != [] ->
        {:error, {:invalid_work_profile, :read_only_repository_refs}}

      not is_nil(attributes.parallel_goal_limit) ->
        {:error, {:invalid_work_profile, :parallel_goal_limit}}

      not is_nil(attributes.emisar_connection_ref) ->
        {:error, {:invalid_work_profile, :emisar_connection_ref}}

      true ->
        :ok
    end
  end

  defp placement(attributes) do
    cond do
      not (is_binary(attributes.environment_ref) and
               Regex.match?(@environment_ref, attributes.environment_ref)) ->
        {:error, {:invalid_work_profile, :environment_ref}}

      not (is_integer(attributes.parallel_goal_limit) and attributes.parallel_goal_limit in 1..3) ->
        {:error, {:invalid_work_profile, :parallel_goal_limit}}

      optional_reference(attributes.emisar_connection_ref, :emisar_connection_ref, 64) != :ok ->
        {:error, {:invalid_work_profile, :emisar_connection_ref}}

      true ->
        read_only(attributes)
    end
  end

  defp read_only(%{read_only_repository_refs: []}), do: :ok

  defp read_only(%{read_only_repository_refs: refs, repository_ref: repository_ref} = attributes)
       when is_binary(repository_ref) and is_list(refs) do
    context = %{
      context_ref: attributes.environment_ref,
      parallel_goal_limit: attributes.parallel_goal_limit,
      primary_repository: repository_ref,
      read_only_repositories: refs
    }

    case RepositoryContext.prepare(context, repository_ref) do
      {:ok, _context} -> :ok
      {:error, :invalid} -> {:error, {:invalid_work_profile, :read_only_repository_refs}}
    end
  end

  defp read_only(_attributes), do: {:error, {:invalid_work_profile, :read_only_repository_refs}}

  defp attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> attributes(),
       else: {:error, {:invalid_work_profile, :fields}}
  end

  defp attributes(%{} = attributes) do
    keys = Map.keys(attributes) |> Enum.sort()

    if Enum.all?(@base_fields, &(&1 in keys)) and keys -- @fields == [] do
      {:ok,
       attributes
       |> Map.put_new(:authority_digest, nil)
       |> Map.put_new(:class_policies, nil)
       |> Map.put_new(:emisar_connection_ref, nil)
       |> Map.put_new(:environment_ref, nil)
       |> Map.put_new(:parallel_goal_limit, nil)
       |> Map.put_new(:read_only_repository_refs, [])}
    else
      {:error, {:invalid_work_profile, :fields}}
    end
  end

  defp attributes(_attributes), do: {:error, {:invalid_work_profile, :fields}}

  defp digest(value) do
    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
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
    if Map.keys(policies) |> Enum.sort() == Enum.sort(@work_classes) do
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

  @spec repository_context_document(map() | nil) :: map() | nil
  def repository_context_document(context), do: RepositoryContext.document(context)

  defp maybe_put_authority_digest(document, nil), do: document

  defp maybe_put_authority_digest(document, authority_digest),
    do: Map.put(document, "authority_digest", authority_digest)

  defp maybe_put(document, _key, nil), do: document
  defp maybe_put(document, key, value), do: Map.put(document, key, value)

  defp present_list([]), do: nil
  defp present_list(values), do: values

  defp maybe_put_policy_repository_context(policy, nil), do: policy

  defp maybe_put_policy_repository_context(policy, context),
    do: Map.put(policy, :repository_context, repository_context_document(context))

  defp reference(value, field, maximum) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_work_profile, field}}
  end
end
