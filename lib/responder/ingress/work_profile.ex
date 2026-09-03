defmodule Responder.Ingress.WorkProfile do
  @moduledoc """
  Host-owned execution placement frozen beside one ingress occurrence.

  Source payloads never construct this value. An authenticated adapter or
  trusted route binds the Coop policy and optional repository scope before the
  input enters durable admission custody.
  """

  @work_classes [:conversational, :standard, :deep]
  @base_fields [:policy, :policy_digest, :repository_ref]
  @fields @base_fields ++ [:class_policies]
  @enforce_keys @base_fields
  defstruct @base_fields ++ [class_policies: nil]

  @type t :: %__MODULE__{
          policy: String.t(),
          policy_digest: String.t(),
          repository_ref: String.t() | nil,
          class_policies:
            %{required(atom()) => %{policy: String.t(), policy_digest: String.t()}} | nil
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- attributes(attributes),
         :ok <- reference(attributes.policy, :policy, 1_024),
         :ok <- digest(attributes.policy_digest),
         :ok <- optional_reference(attributes.repository_ref, :repository_ref, 1_024),
         {:ok, class_policies} <- class_policies(Map.get(attributes, :class_policies)) do
      attributes = Map.put(attributes, :class_policies, class_policies)
      {:ok, struct!(__MODULE__, attributes)}
    end
  end

  @spec prepare(t() | keyword() | map() | nil) :: {:ok, t() | nil} | {:error, term()}
  def prepare(nil), do: {:ok, nil}
  def prepare(%__MODULE__{} = profile), do: profile |> Map.from_struct() |> new()
  def prepare(attributes), do: new(attributes)

  @spec policy_for(t(), atom()) ::
          {:ok, %{name: String.t(), digest: String.t(), repository_ref: String.t() | nil}}
          | {:error, term()}
  def policy_for(%__MODULE__{} = profile, work_class) when work_class in @work_classes do
    selected =
      case profile.class_policies do
        nil -> %{policy: profile.policy, policy_digest: profile.policy_digest}
        policies -> Map.fetch!(policies, work_class)
      end

    {:ok,
     %{
       digest: selected.policy_digest,
       name: selected.policy,
       repository_ref: profile.repository_ref
     }}
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
  end

  @spec restore(map()) :: {:ok, t()} | {:error, term()}
  def restore(
        %{
          "class_policies" => class_policies,
          "policy" => policy,
          "policy_digest" => policy_digest,
          "repository_ref" => repository_ref
        } = document
      )
      when map_size(document) == 4 do
    new(%{
      class_policies: restore_class_policies(class_policies),
      policy: policy,
      policy_digest: policy_digest,
      repository_ref: repository_ref
    })
  end

  def restore(_document), do: {:error, {:invalid_work_profile, :fields}}

  defp attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> attributes(),
       else: {:error, {:invalid_work_profile, :fields}}
  end

  defp attributes(%{} = attributes) do
    keys = Map.keys(attributes) |> Enum.sort()

    cond do
      keys == Enum.sort(@base_fields) -> {:ok, Map.put(attributes, :class_policies, nil)}
      keys == Enum.sort(@fields) -> {:ok, attributes}
      true -> {:error, {:invalid_work_profile, :fields}}
    end
  end

  defp attributes(_attributes), do: {:error, {:invalid_work_profile, :fields}}

  defp digest(value) do
    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: :ok,
      else: {:error, {:invalid_work_profile, :policy_digest}}
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
       when map_size(attributes) == 2 do
    with :ok <- reference(policy, :policy, 1_024),
         :ok <- digest(policy_digest) do
      {:ok, %{policy: policy, policy_digest: policy_digest}}
    end
  end

  defp class_policy(_attributes), do: {:error, :class_policy}

  defp class_policies_document(nil), do: nil

  defp class_policies_document(policies) do
    Map.new(policies, fn {work_class, policy} ->
      {Atom.to_string(work_class),
       %{"policy" => policy.policy, "policy_digest" => policy.policy_digest}}
    end)
  end

  defp restore_class_policies(nil), do: nil

  defp restore_class_policies(%{} = policies) do
    Map.new(policies, fn
      {work_class, %{"policy" => policy, "policy_digest" => policy_digest}}
      when work_class in ~w(conversational standard deep) ->
        {String.to_existing_atom(work_class), %{policy: policy, policy_digest: policy_digest}}

      {work_class, policy} ->
        {work_class, policy}
    end)
  end

  defp restore_class_policies(value), do: value

  defp reference(value, field, maximum) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_work_profile, field}}
  end
end
