defmodule Responder.Ingress.WorkProfile do
  @moduledoc """
  Host-owned execution placement frozen beside one ingress occurrence.

  Source payloads never construct this value. An authenticated adapter or
  trusted route binds the Coop policy and optional repository scope before the
  input enters durable admission custody.
  """

  alias Responder.Work.RepositoryContext

  @work_classes [:conversational, :standard, :deep]
  @base_fields [:policy, :policy_digest, :repository_ref]
  @fields @base_fields ++ [:authority_digest, :class_policies, :repository_context]
  @enforce_keys @base_fields
  defstruct @base_fields ++ [authority_digest: nil, class_policies: nil, repository_context: nil]

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
          repository_context:
            %{
              context_ref: String.t(),
              parallel_goal_limit: 1..3,
              primary_repository: String.t(),
              read_only_repositories: [String.t()]
            }
            | nil
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes), do: build(attributes, false)

  defp build(attributes, allow_legacy) do
    with {:ok, attributes} <- attributes(attributes),
         :ok <- reference(attributes.policy, :policy, 1_024),
         :ok <- digest(attributes.policy_digest),
         :ok <- optional_digest(attributes.authority_digest, :authority_digest),
         :ok <- optional_reference(attributes.repository_ref, :repository_ref, 1_024),
         {:ok, class_policies} <- class_policies(Map.get(attributes, :class_policies)),
         {:ok, repository_context} <-
           prepare_repository_context(
             Map.get(attributes, :repository_context),
             attributes.repository_ref
           ),
         :ok <-
           authority_equivalence(attributes.authority_digest, class_policies, allow_legacy) do
      attributes =
        attributes
        |> Map.put(:class_policies, class_policies)
        |> Map.put(:repository_context, repository_context)

      {:ok, struct!(__MODULE__, attributes)}
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
        name: selected.policy,
        repository_ref: profile.repository_ref
      }
      |> maybe_put_policy_repository_context(profile.repository_context)

    {:ok, policy}
  end

  def policy_for(%__MODULE__{}, _work_class),
    do: {:error, {:invalid_work_profile, :work_class}}

  @spec document(t()) :: map()
  def document(%__MODULE__{} = profile) do
    %{
      "class_policies" => class_policies_document(profile.class_policies),
      "policy" => profile.policy,
      "policy_digest" => profile.policy_digest,
      "repository_ref" => profile.repository_ref
    }
    |> maybe_put_authority_digest(profile.authority_digest)
    |> maybe_put_repository_context(profile.repository_context)
  end

  @spec restore(map()) :: {:ok, t()} | {:error, term()}
  def restore(%{} = document) do
    keys = Map.keys(document) |> Enum.sort()
    required = ~w(class_policies policy policy_digest repository_ref)
    allowed = ["authority_digest", "repository_context" | required]

    if Enum.all?(required, &(&1 in keys)) and keys -- allowed == [] do
      case RepositoryContext.restore(
             document["repository_context"],
             document["repository_ref"]
           ) do
        {:ok, repository_context} ->
          build(
            %{
              authority_digest: Map.get(document, "authority_digest"),
              class_policies: restore_class_policies(document["class_policies"]),
              policy: document["policy"],
              policy_digest: document["policy_digest"],
              repository_context: repository_context,
              repository_ref: document["repository_ref"]
            },
            true
          )

        {:error, :invalid} ->
          {:error, {:invalid_work_profile, :repository_context}}
      end
    else
      {:error, {:invalid_work_profile, :fields}}
    end
  end

  def restore(_document), do: {:error, {:invalid_work_profile, :fields}}

  defp prepare_repository_context(value, repository_ref) do
    case RepositoryContext.prepare(value, repository_ref) do
      {:ok, context} -> {:ok, context}
      {:error, :invalid} -> {:error, {:invalid_work_profile, :repository_context}}
    end
  end

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
       |> Map.put_new(:repository_context, nil)}
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

  defp authority_equivalence(nil, nil, _allow_legacy), do: :ok

  defp authority_equivalence(authority_digest, nil, _allow_legacy)
       when is_binary(authority_digest),
       do: :ok

  defp authority_equivalence(nil, policies, allow_legacy) when is_map(policies) do
    identities =
      policies
      |> Map.values()
      |> Enum.map(&{&1.policy, &1.policy_digest})
      |> Enum.uniq()

    if Enum.all?(policies, fn {_work_class, policy} -> is_nil(policy.authority_digest) end) and
         (allow_legacy or length(identities) == 1),
       do: :ok,
       else: {:error, {:invalid_work_profile, :authority_equivalence}}
  end

  defp authority_equivalence(authority_digest, policies, _allow_legacy) when is_map(policies) do
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

  defp maybe_put_repository_context(document, nil), do: document

  defp maybe_put_repository_context(document, context),
    do: Map.put(document, "repository_context", repository_context_document(context))

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
