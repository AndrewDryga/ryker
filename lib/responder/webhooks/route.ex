defmodule Responder.Webhooks.Route do
  @moduledoc """
  Trusted configuration for one universal webhook route.

  The route owns authentication, delivery destination, and resource bounds.
  None of those fields are read from a webhook payload.
  """

  alias Responder.Ingress.WorkProfile

  @default_max_body_bytes 40_000
  @maximum_body_bytes 40_000
  @default_max_clock_skew_seconds 300
  @required_fields [:auth, :destination, :name]
  @optional_fields [:max_body_bytes, :max_clock_skew_seconds, :work_profile]

  @enforce_keys @required_fields ++ @optional_fields
  defstruct @required_fields ++ @optional_fields

  @type auth :: {:bearer, binary()} | {:hmac_sha256, binary()}
  @type destination :: %{
          transport: String.t(),
          conversation_ref: String.t(),
          thread_ref: String.t() | nil
        }
  @type t :: %__MODULE__{
          auth: auth(),
          destination: destination(),
          max_body_bytes: pos_integer(),
          max_clock_skew_seconds: pos_integer(),
          name: String.t(),
          work_profile: WorkProfile.t() | nil
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         {:ok, work_profile} <-
           WorkProfile.prepare(Map.get(attributes, :work_profile)),
         attributes <- Map.put(attributes, :work_profile, work_profile),
         route <- struct!(__MODULE__, attributes),
         :ok <- validate(route) do
      {:ok, route}
    end
  end

  defp normalize_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      attributes |> Map.new() |> normalize_attributes()
    else
      {:error, {:invalid_webhook_route, :fields}}
    end
  end

  defp normalize_attributes(%{} = attributes) do
    keys = Map.keys(attributes)
    allowed = @required_fields ++ @optional_fields

    if Enum.sort(keys -- allowed) == [] and Enum.all?(@required_fields, &(&1 in keys)) do
      {:ok,
       attributes
       |> Map.put_new(:max_body_bytes, @default_max_body_bytes)
       |> Map.put_new(:max_clock_skew_seconds, @default_max_clock_skew_seconds)
       |> Map.put_new(:work_profile, nil)}
    else
      {:error, {:invalid_webhook_route, :fields}}
    end
  end

  defp normalize_attributes(_attributes), do: {:error, {:invalid_webhook_route, :fields}}

  defp validate(%__MODULE__{} = route) do
    validations = [
      {valid_auth?(route.auth), :auth},
      {valid_destination?(route.destination), :destination},
      {positive_bound?(route.max_body_bytes, 1_024, @maximum_body_bytes), :max_body_bytes},
      {positive_bound?(route.max_clock_skew_seconds, 1, 3_600), :max_clock_skew_seconds},
      {reference?(route.name, 128), :name}
    ]

    Enum.reduce_while(validations, :ok, fn
      {true, _field}, :ok -> {:cont, :ok}
      {false, field}, :ok -> {:halt, {:error, {:invalid_webhook_route, field}}}
    end)
  end

  defp valid_auth?({:bearer, secret}), do: secret?(secret, 16)
  defp valid_auth?({:hmac_sha256, secret}), do: secret?(secret, 32)
  defp valid_auth?(_auth), do: false

  defp secret?(secret, minimum) do
    is_binary(secret) and byte_size(secret) >= minimum and byte_size(secret) <= 1_024
  end

  defp valid_destination?(
         %{transport: transport, conversation_ref: conversation, thread_ref: thread} = destination
       ) do
    map_size(destination) == 3 and reference?(transport, 1_024) and
      reference?(conversation, 1_024) and (is_nil(thread) or reference?(thread, 1_024))
  end

  defp valid_destination?(_destination), do: false

  defp positive_bound?(value, minimum, maximum),
    do: is_integer(value) and value >= minimum and value <= maximum

  defp reference?(value, maximum) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= maximum
  end
end
