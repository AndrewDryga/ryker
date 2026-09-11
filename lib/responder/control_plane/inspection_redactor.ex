defmodule Responder.ControlPlane.InspectionRedactor do
  @moduledoc "Sanitized inspection artifacts. Original bytes never cross the browser boundary."
  alias Responder.CanonicalJSON

  @marker "[redacted]"
  @secret_key ~r/(?:^|[_-])(?:authorization|cookie|password|passwd|secret|secrets|token|api[_-]?key|private[_-]?key|signing[_-]?key|userinfo|credential|credentials)(?:$|[_-])/i
  @maximum_source_bytes 2 * 1_024 * 1_024

  def artifact(value, options \\ [])

  def artifact(nil, options) do
    %{
      state: if(options[:expired], do: :expired, else: :not_recorded),
      text: nil,
      sha256: nil,
      bytes: nil,
      redacted: false,
      truncated: false
    }
  end

  def artifact(value, options) do
    original = if is_binary(value), do: value, else: CanonicalJSON.encode!(value)
    base = %{state: :retained, sha256: digest(original), bytes: byte_size(original)}

    cond do
      Keyword.get(options, :disclosed, true) == false ->
        # Nobody has opened this body, so nothing sanitizes, re-encodes or
        # renders it. Collapsing the rendered HTML alone still paid for every
        # byte of every unopened artifact on every refresh.
        Map.merge(base, %{
          state: :collapsed,
          text: nil,
          redacted: false,
          truncated: false
        })

      byte_size(original) > @maximum_source_bytes ->
        Map.merge(base, %{
          text: "Artifact exceeds the inspection safety bound.",
          redacted: false,
          truncated: true
        })

      true ->
        disclosed_artifact(value, original, base, options)
    end
  end

  defp disclosed_artifact(value, original, base, options) do
    secrets = Keyword.get_lazy(options, :secrets, &configured_secrets/0)
    document = decode(value)
    sanitized = sanitize(document, secrets, 0)

    text =
      cond do
        options[:preserve_format] && sanitized == document && unique_keys?(original) -> original
        is_binary(sanitized) -> sanitized
        true -> Jason.encode!(sanitized, pretty: true)
      end

    maximum = Keyword.get(options, :max_bytes, 512 * 1_024)
    truncated = byte_size(text) > maximum
    text = if truncated, do: utf8_prefix(text, maximum) <> "\n[display truncated]", else: text
    Map.merge(base, %{text: text, redacted: sanitized != document, truncated: truncated})
  end

  def configured_secrets do
    Application.get_all_env(:responder)
    |> secret_values()
    |> Enum.filter(&(byte_size(&1) >= 8))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  @doc false
  def secret_values(value), do: secret_values(value, false)

  defp secret_values(value, inherited) when is_struct(value),
    do: secret_values(Map.from_struct(value), inherited)

  defp secret_values(value, inherited) when is_map(value),
    do: Enum.flat_map(value, &secret_values(&1, inherited))

  defp secret_values({key, value}, inherited),
    do: secret_values(value, inherited or sensitive?(key))

  defp secret_values(value, inherited) when is_list(value),
    do: Enum.flat_map(value, &secret_values(&1, inherited))

  defp secret_values(value, true) when is_binary(value), do: [value]
  defp secret_values(_value, _inherited), do: []

  defp sanitize(_value, _secrets, depth) when depth > 32, do: "[inspection depth limit]"

  # A provider-cut JSON string cannot be safely inspected as a structured document.
  defp sanitize(%{"truncated" => true, "preview" => _} = value, secrets, depth),
    do:
      value
      |> Map.delete("preview")
      |> sanitize(secrets, depth)
      |> Map.put("preview", "[partial structured content withheld]")

  defp sanitize(value, secrets, depth) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      {scrub(to_string(key), secrets),
       if(sensitive?(key), do: @marker, else: sanitize(nested, secrets, depth + 1))}
    end)
  end

  defp sanitize(value, secrets, depth) when is_list(value),
    do: Enum.map(value, &sanitize(&1, secrets, depth + 1))

  defp sanitize(value, secrets, depth) when is_binary(value) do
    case decode(value) do
      decoded when is_map(decoded) or is_list(decoded) ->
        decoded |> sanitize(secrets, depth + 1) |> Jason.encode!()

      _text ->
        scrub(value, secrets)
    end
  end

  defp sanitize(value, _secrets, _depth), do: value

  defp decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, parsed} when is_map(parsed) or is_list(parsed) -> parsed
      _other -> value
    end
  end

  defp decode(value), do: value

  defp unique_keys?(text) do
    case Jason.decode(text, objects: :ordered_objects) do
      {:ok, value} -> unique_object?(value)
      _ -> true
    end
  end

  defp unique_object?(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))

    length(keys) == MapSet.size(MapSet.new(keys)) &&
      Enum.all?(values, &unique_object?(elem(&1, 1)))
  end

  defp unique_object?(values) when is_list(values), do: Enum.all?(values, &unique_object?/1)
  defp unique_object?(_), do: true

  defp sensitive?(key) when is_atom(key) or is_binary(key),
    do:
      Regex.match?(@secret_key, String.replace(to_string(key), ~r/([a-z0-9])([A-Z])/, "\\1_\\2"))

  defp sensitive?(_key), do: false

  defp scrub(value, secrets) do
    value =
      Enum.reduce(secrets, value, fn secret, text ->
        if is_binary(secret) and secret != "",
          do: String.replace(text, secret, @marker),
          else: text
      end)

    value
    |> scrub_urls()
    |> String.replace(
      ~r/-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----.*?-----END (?:[A-Z ]+ )?PRIVATE KEY-----/s,
      @marker
    )
    |> String.replace(~r/(?i)\bBearer\s+[A-Za-z0-9._~+\/-]+/, "Bearer [redacted]")
    |> String.replace(~r/\b(?:xox[baprs]-|gh[pousr]_|github_pat_|sk-)[A-Za-z0-9_-]+/, @marker)
    |> String.replace(
      ~r/(?i)\b(password|passwd|(?:access[_-]?)?token|(?:client[_-]?)?secret|api[_-]?key)["']?\s*[:=]\s*(?:"[^"\n]*"|'[^'\n]*'|[^\s,;]+)/,
      "\\1=[redacted]"
    )
  end

  defp scrub_urls(value) do
    Regex.replace(
      ~r/(?<=<)https?:\/\/[^\s<>"'|]+(?=\|[^<>\r\n]*>)|https?:\/\/[^\s<>"']+/,
      value,
      fn url ->
        # Prose and Markdown delimiters are not part of a signed URL. Scrub the
        # complete URL before generic token assignments can consume its closing ).
        resource = String.replace(url, ~r/[).,;!?]+$/, "")
        suffix = binary_part(url, byte_size(resource), byte_size(url) - byte_size(resource))
        uri = URI.parse(resource)
        # Signed links and opaque query parameters are not inspection credentials.
        # Preserve the useful resource path; omit query and fragment wholesale.
        URI.to_string(%{uri | userinfo: nil, query: nil, fragment: nil}) <> suffix
      end
    )
  end

  defp utf8_prefix(text, maximum), do: text |> binary_part(0, maximum) |> valid_prefix()

  defp valid_prefix(text) do
    if String.valid?(text),
      do: text,
      else: text |> binary_part(0, byte_size(text) - 1) |> valid_prefix()
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
