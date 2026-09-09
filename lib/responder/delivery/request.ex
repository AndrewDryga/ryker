defmodule Responder.Delivery.Request do
  @moduledoc """
  One immutable, host-routed platform delivery.

  A request contains no credentials and cannot choose a destination after it
  enters custody. Platform adapters may only translate this exact intent into
  their own API shape.
  """

  alias Responder.CanonicalJSON

  @enforce_keys [
    :conversation_ref,
    :document,
    :kind,
    :ref,
    :source_item_ref,
    :thread_ref,
    :transport
  ]
  @fields @enforce_keys ++ [:artifacts]
  @required_fields Enum.sort(@enforce_keys)
  @all_fields Enum.sort(@fields)
  defstruct @enforce_keys ++ [artifacts: []]

  @type t :: %__MODULE__{
          conversation_ref: String.t(),
          artifacts: [map()],
          document: map(),
          kind: :message | :reaction,
          ref: String.t(),
          source_item_ref: String.t() | nil,
          thread_ref: String.t() | nil,
          transport: String.t()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         request <- struct!(__MODULE__, attributes),
         :ok <- validate(request) do
      {:ok, request}
    end
  end

  defp normalize_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      attributes |> Map.new() |> normalize_attributes()
    else
      {:error, {:invalid_delivery_request, :fields}}
    end
  end

  defp normalize_attributes(%{} = attributes) do
    case Map.keys(attributes) |> Enum.sort() do
      @required_fields -> {:ok, Map.put(attributes, :artifacts, [])}
      @all_fields -> {:ok, attributes}
      _invalid -> {:error, {:invalid_delivery_request, :fields}}
    end
  end

  defp normalize_attributes(_attributes), do: {:error, {:invalid_delivery_request, :fields}}

  defp validate(%__MODULE__{} = request) do
    with :ok <- reference(request.ref, :ref),
         :ok <- transport(request.transport),
         :ok <- reference(request.conversation_ref, :conversation_ref),
         :ok <- optional_reference(request.thread_ref, :thread_ref),
         :ok <- artifacts(request.artifacts),
         :ok <- CanonicalJSON.validate(request.document, max_bytes: 512 * 1_024) do
      validate_kind(request)
    else
      {:error, {:invalid_delivery_request, _field}} = error -> error
      {:error, _reason} -> {:error, {:invalid_delivery_request, :document}}
    end
  end

  defp validate_kind(%__MODULE__{
         document: %{"message" => message} = document,
         kind: :message,
         source_item_ref: nil
       }) do
    with :ok <- message_document(document),
         true <- text?(message) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_delivery_request, :message}}
    end
  end

  defp validate_kind(%__MODULE__{
         document: %{"emoji_name" => emoji_name} = document,
         kind: :reaction,
         source_item_ref: source_item_ref
       })
       when map_size(document) in 1..2 do
    with :ok <- reference(source_item_ref, :source_item_ref),
         :ok <- reaction_document(document),
         true <- text?(emoji_name) do
      :ok
    else
      {:error, _reason} = error -> error
      false -> {:error, {:invalid_delivery_request, :emoji_name}}
    end
  end

  defp validate_kind(%__MODULE__{kind: kind}),
    do: {:error, {:invalid_delivery_request, kind}}

  defp reaction_document(%{"emoji_name" => _emoji_name} = document)
       when map_size(document) == 1,
       do: :ok

  defp reaction_document(%{"action" => action, "emoji_name" => _emoji_name} = document)
       when map_size(document) == 2,
       do:
         if(action in ["add", "remove"],
           do: :ok,
           else: {:error, {:invalid_delivery_request, :reaction}}
         )

  defp reaction_document(_document), do: {:error, {:invalid_delivery_request, :reaction}}

  defp message_document(%{"message" => _message} = document) when map_size(document) == 1,
    do: bounded_message(document["message"])

  defp message_document(%{"message" => _message, "records" => records} = document)
       when map_size(document) == 2 do
    with :ok <- bounded_message(document["message"]), do: validate_records(records)
  end

  defp message_document(_document), do: {:error, {:invalid_delivery_request, :document}}

  defp bounded_message(message) do
    if text?(message) and String.length(message) <= 20_000,
      do: :ok,
      else: {:error, {:invalid_delivery_request, :message}}
  end

  defp validate_records(records) when is_list(records) and length(records) <= 64 do
    if Enum.all?(records, &valid_record?/1),
      do: :ok,
      else: {:error, {:invalid_delivery_request, :records}}
  end

  defp validate_records(_records), do: {:error, {:invalid_delivery_request, :records}}

  defp valid_record?(%{"presentation" => presentation} = record)
       when map_size(record) == 5 and is_map(presentation),
       do: valid_record?(Map.delete(record, "presentation"))

  defp valid_record?(
         %{"kind" => kind, "payload" => payload, "ref" => ref, "status" => status} = record
       )
       when map_size(record) == 4 and is_map(payload) do
    text?(kind) and byte_size(kind) <= 64 and text?(status) and byte_size(status) <= 64 and
      text?(ref) and byte_size(ref) <= 256
  end

  defp valid_record?(_record), do: false

  defp artifacts(values) when is_list(values) and length(values) <= 5 do
    if Enum.sum(Enum.map(values, &artifact_bytes/1)) <= 8 * 1_024 * 1_024 and
         Enum.all?(values, &artifact?/1) and unique_artifacts?(values) do
      :ok
    else
      {:error, {:invalid_delivery_request, :artifacts}}
    end
  end

  defp artifacts(_values), do: {:error, {:invalid_delivery_request, :artifacts}}

  defp artifact?(
         %{
           "bytes" => bytes,
           "data" => data,
           "media_type" => media_type,
           "name" => name,
           "ref" => ref,
           "sha256" => sha256
         } = artifact
       )
       when map_size(artifact) == 6 and is_integer(bytes) and is_binary(data) and
              is_binary(media_type) and is_binary(name) and is_binary(ref) and is_binary(sha256) do
    Enum.all?([
      bytes in 1..(8 * 1_024 * 1_024),
      bytes == byte_size(data),
      safe_name?(name),
      reference?(ref),
      Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256),
      digest(data) == sha256,
      media_matches?(media_type, data)
    ])
  end

  defp artifact?(_artifact), do: false

  defp artifact_bytes(%{"bytes" => bytes}) when is_integer(bytes) and bytes > 0, do: bytes
  defp artifact_bytes(_artifact), do: 8 * 1_024 * 1_024 + 1

  defp unique_artifacts?(artifacts) do
    refs = Enum.map(artifacts, & &1["ref"])
    digests = Enum.map(artifacts, & &1["sha256"])
    Enum.uniq(refs) == refs and Enum.uniq(digests) == digests
  end

  defp safe_name?(value) do
    text?(value) and byte_size(value) <= 255 and value not in [".", ".."] and
      not String.contains?(value, ["/", "\\"]) and
      not Enum.any?(String.to_charlist(value), &(&1 < 32 or &1 == 127))
  end

  defp reference?(value),
    do: text?(value) and byte_size(value) <= 256 and Regex.match?(~r/\A[A-Za-z0-9_.:-]+\z/, value)

  defp media_matches?("image/png", <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>>), do: true
  defp media_matches?("image/jpeg", <<255, 216, 255, _::binary>>), do: true
  defp media_matches?("image/gif", <<"GIF87a", _::binary>>), do: true
  defp media_matches?("image/gif", <<"GIF89a", _::binary>>), do: true
  defp media_matches?("image/webp", <<"RIFF", _::binary-size(4), "WEBP", _::binary>>), do: true
  defp media_matches?(_media_type, _data), do: false

  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

  defp transport(value) do
    if is_binary(value) and Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, value),
      do: :ok,
      else: {:error, {:invalid_delivery_request, :transport}}
  end

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)

  defp reference(value, field) do
    if text?(value) and byte_size(value) <= 1_024,
      do: :ok,
      else: {:error, {:invalid_delivery_request, field}}
  end

  defp text?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != ""
  end
end
