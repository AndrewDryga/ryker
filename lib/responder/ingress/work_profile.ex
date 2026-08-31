defmodule Responder.Ingress.WorkProfile do
  @moduledoc """
  Host-owned execution placement frozen beside one ingress occurrence.

  Source payloads never construct this value. An authenticated adapter or
  trusted route binds the Coop policy and optional repository scope before the
  input enters durable admission custody.
  """

  @fields [:policy, :policy_digest, :repository_ref]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          policy: String.t(),
          policy_digest: String.t(),
          repository_ref: String.t() | nil
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- attributes(attributes),
         :ok <- reference(attributes.policy, :policy, 1_024),
         :ok <- digest(attributes.policy_digest),
         :ok <- optional_reference(attributes.repository_ref, :repository_ref, 1_024) do
      {:ok, struct!(__MODULE__, attributes)}
    end
  end

  @spec prepare(t() | keyword() | map() | nil) :: {:ok, t() | nil} | {:error, term()}
  def prepare(nil), do: {:ok, nil}
  def prepare(%__MODULE__{} = profile), do: profile |> Map.from_struct() |> new()
  def prepare(attributes), do: new(attributes)

  defp attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> attributes(),
       else: {:error, {:invalid_work_profile, :fields}}
  end

  defp attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_work_profile, :fields}}
  end

  defp attributes(_attributes), do: {:error, {:invalid_work_profile, :fields}}

  defp digest(value) do
    if is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: :ok,
      else: {:error, {:invalid_work_profile, :policy_digest}}
  end

  defp optional_reference(nil, _field, _maximum), do: :ok
  defp optional_reference(value, field, maximum), do: reference(value, field, maximum)

  defp reference(value, field, maximum) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_work_profile, field}}
  end
end
