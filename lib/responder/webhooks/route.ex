defmodule Responder.Webhooks.Route do
  @moduledoc """
  Trusted configuration for one authenticated webhook route.

  The route owns authentication, delivery destination, and resource bounds.
  None of those fields are read from a webhook payload.
  """

  alias Responder.Ingress.WorkProfile

  @default_max_body_bytes 40_000
  @maximum_body_bytes 40_000
  @default_max_clock_skew_seconds 300
  @required_fields [:auth, :destination, :name]
  @optional_fields [
    :adapter,
    :max_body_bytes,
    :max_clock_skew_seconds,
    :publication_lifecycle,
    :work_profile
  ]
  @mapping_required [:event_id, :status, :title]
  @mapping_optional [
    :annotations,
    :ends_at,
    :incident_id,
    :item_id,
    :labels,
    :revision,
    :severity,
    :source_url,
    :starts_at,
    :summary
  ]

  @enforce_keys @required_fields ++ @optional_fields
  defstruct @required_fields ++ @optional_fields

  @type auth :: {:bearer, binary()} | {:hmac_sha256, binary()}
  @type adapter ::
          %{kind: :universal}
          | %{kind: :grafana, group_by_labels: [String.t()]}
          | %{
              kind: :mapped_json,
              group_by_labels: [String.t()],
              mapping: %{atom() => String.t() | nil}
            }
  @type destination :: %{
          transport: String.t(),
          conversation_ref: String.t(),
          thread_ref: String.t() | nil
        }
  @type publication_lifecycle :: %{
          environments: [String.t()],
          kinds: [String.t()],
          repositories: [String.t()],
          targets: [String.t()]
        }
  @type t :: %__MODULE__{
          adapter: adapter(),
          auth: auth(),
          destination: destination(),
          max_body_bytes: pos_integer(),
          max_clock_skew_seconds: pos_integer(),
          name: String.t(),
          publication_lifecycle: publication_lifecycle() | nil,
          work_profile: WorkProfile.t() | nil
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         {:ok, adapter} <- prepare_adapter(Map.get(attributes, :adapter)),
         {:ok, publication_lifecycle} <-
           prepare_publication_lifecycle(Map.get(attributes, :publication_lifecycle)),
         {:ok, work_profile} <-
           WorkProfile.prepare(Map.get(attributes, :work_profile)),
         attributes <-
           attributes
           |> Map.put(:adapter, adapter)
           |> Map.put(:publication_lifecycle, publication_lifecycle)
           |> Map.put(:work_profile, work_profile),
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
       |> Map.put_new(:adapter, %{kind: :universal})
       |> Map.put_new(:max_body_bytes, @default_max_body_bytes)
       |> Map.put_new(:max_clock_skew_seconds, @default_max_clock_skew_seconds)
       |> Map.put_new(:publication_lifecycle, nil)
       |> Map.put_new(:work_profile, nil)}
    else
      {:error, {:invalid_webhook_route, :fields}}
    end
  end

  defp normalize_attributes(_attributes), do: {:error, {:invalid_webhook_route, :fields}}

  defp prepare_adapter(nil), do: {:ok, %{kind: :universal}}

  defp prepare_adapter(%{kind: :universal} = adapter) when map_size(adapter) == 1,
    do: {:ok, adapter}

  defp prepare_adapter(%{kind: :grafana} = adapter) do
    with true <- Map.keys(adapter) -- [:kind, :group_by_labels] == [],
         {:ok, labels} <- prepare_group_labels(Map.get(adapter, :group_by_labels, [])) do
      {:ok, %{kind: :grafana, group_by_labels: labels}}
    else
      _invalid -> {:error, {:invalid_webhook_route, :adapter}}
    end
  end

  defp prepare_adapter(%{kind: :mapped_json, mapping: mapping} = adapter) do
    with true <- Map.keys(adapter) -- [:kind, :group_by_labels, :mapping] == [],
         {:ok, labels} <- prepare_group_labels(Map.get(adapter, :group_by_labels, [])),
         {:ok, mapping} <- prepare_mapping(mapping) do
      {:ok, %{kind: :mapped_json, group_by_labels: labels, mapping: mapping}}
    else
      _invalid -> {:error, {:invalid_webhook_route, :adapter}}
    end
  end

  defp prepare_adapter(_adapter), do: {:error, {:invalid_webhook_route, :adapter}}

  defp prepare_publication_lifecycle(nil), do: {:ok, nil}

  defp prepare_publication_lifecycle(%{} = scope) when map_size(scope) == 4 do
    with {:ok, environments} <- scope_list(scope[:environments]),
         {:ok, kinds} <- scope_list(scope[:kinds]),
         true <- Enum.all?(kinds, &(&1 in ~w(deployment terraform))),
         {:ok, repositories} <- scope_list(scope[:repositories]),
         {:ok, targets} <- scope_list(scope[:targets]) do
      {:ok,
       %{
         environments: environments,
         kinds: kinds,
         repositories: repositories,
         targets: targets
       }}
    else
      _invalid -> {:error, {:invalid_webhook_route, :publication_lifecycle}}
    end
  end

  defp prepare_publication_lifecycle(_scope),
    do: {:error, {:invalid_webhook_route, :publication_lifecycle}}

  defp scope_list(values) when is_list(values) and values != [] and length(values) <= 64 do
    prepared = Enum.sort(Enum.uniq(values))

    if length(prepared) == length(values) and Enum.all?(prepared, &reference?(&1, 256)),
      do: {:ok, prepared},
      else: {:error, :scope}
  end

  defp scope_list(_values), do: {:error, :scope}

  defp prepare_group_labels(labels) when is_list(labels) and length(labels) <= 16 do
    if labels != [] and Enum.uniq(labels) == labels and Enum.all?(labels, &path_segment?/1),
      do: {:ok, labels},
      else: if(labels == [], do: {:ok, []}, else: {:error, :group_by_labels})
  end

  defp prepare_group_labels(_labels), do: {:error, :group_by_labels}

  defp prepare_mapping(mapping) when is_map(mapping) do
    keys = Map.keys(mapping)
    allowed = @mapping_required ++ @mapping_optional

    if keys -- allowed == [] and Enum.all?(@mapping_required, &(&1 in keys)) do
      prepared = Map.new(allowed, &{&1, Map.get(mapping, &1)})

      if Enum.all?(@mapping_required, &path?(prepared[&1])) and
           Enum.all?(@mapping_optional, &(is_nil(prepared[&1]) or path?(prepared[&1]))) do
        {:ok, prepared}
      else
        {:error, :mapping}
      end
    else
      {:error, :mapping}
    end
  end

  defp prepare_mapping(_mapping), do: {:error, :mapping}

  defp path?(value) when is_binary(value) and byte_size(value) <= 256 do
    parts = String.split(value, ".")
    parts != [] and length(parts) <= 16 and Enum.all?(parts, &path_segment?/1)
  end

  defp path?(_value), do: false

  defp path_segment?(value) when is_binary(value) and byte_size(value) <= 64,
    do: Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_-]*\z/, value)

  defp path_segment?(_value), do: false

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
