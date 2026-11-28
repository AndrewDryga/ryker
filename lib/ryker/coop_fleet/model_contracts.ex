defmodule Ryker.CoopFleet.ModelContracts do
  @moduledoc "Native model HTTP routes exported from Coop's provider adapters."
  alias Ryker.Work
  @external_resource Path.expand("../../../priv/coop-model-contracts.json", __DIR__)
  @contracts @external_resource |> File.read!() |> Jason.decode!()
  @secret_headers ~w(authorization proxy-authorization cookie x-api-key x-goog-api-key x-coop-model-grant chatgpt-account-id host connection transfer-encoding content-length upgrade)

  def route(provider, selection, method, host, path, query) do
    routes = get_in(@contracts, ["providers", provider, selection]) || []

    case Enum.find(routes, &matches?(&1, method, host, path, query)) do
      nil -> {:error, :model_route_refused}
      route -> {:ok, route}
    end
  end

  def headers(route, account, headers) do
    clean =
      Enum.reject(headers, fn {key, _value} ->
        String.downcase(key) in @secret_headers or
          String.starts_with?(String.downcase(key), "sec-websocket-")
      end)

    if route["CredentialFree"] do
      clean
    else
      headers = [
        {String.downcase(route["Header"]), route["HeaderPrefix"] <> account["credential"]} | clean
      ]

      case route["AccountHeader"] do
        "" -> headers
        name -> [{String.downcase(name), account["account_id"]} | headers]
      end
    end
  end

  def models(job, provider, account) do
    roles = get_in(job, ["preset", "roles"]) || []

    (List.wrap(job["targets"]) ++ Enum.flat_map(roles, &List.wrap(&1["targets"])))
    |> Enum.filter(
      &(String.starts_with?(&1, provider <> ":") and String.ends_with?(&1, "@" <> account))
    )
    |> Enum.map(fn target ->
      Work.ExecutionTarget.parts(target).model |> String.trim_trailing("+fast")
    end)
    |> Enum.uniq()
  end

  def model_allowed?(model, allowed) when is_binary(model) do
    Enum.any?(allowed, fn
      ^model ->
        true

      family when family in ["sonnet", "opus", "haiku", "fable"] ->
        String.starts_with?(model, "claude-" <> family <> "-")

      _other ->
        false
    end)
  end

  def model_allowed?(_model, _allowed), do: false

  defp matches?(route, method, host, path, query) do
    route["Method"] == method and route["Host"] == host and
      path?(route, path) and query?(route, query)
  end

  defp path?(%{"Segment" => ""} = route, path), do: route["Path"] == path

  defp path?(route, path) do
    prefix = route["Path"]
    suffix = route["Suffix"]

    if String.starts_with?(path, prefix) and String.ends_with?(path, suffix) do
      value =
        binary_part(
          path,
          byte_size(prefix),
          byte_size(path) - byte_size(prefix) - byte_size(suffix)
        )

      case route["Segment"] do
        "sha1" -> Regex.match?(~r/\A[0-9a-f]{40}\z/, value)
        "uuid" -> match?({:ok, _}, Ecto.UUID.cast(value))
        "token" -> Regex.match?(~r/\A[a-zA-Z0-9_-]{1,1024}\z/, value)
        _unsupported -> false
      end
    else
      false
    end
  end

  defp query?(%{"Queries" => queries, "Query" => expected}, raw) when queries in [nil, []],
    do: raw == expected

  defp query?(%{"Queries" => rules}, raw) do
    parts = URI.query_decoder(raw) |> Enum.to_list()
    keys = Enum.map(parts, &elem(&1, 0))

    length(keys) == length(Enum.uniq(keys)) and
      Enum.all?(parts, fn {key, value} ->
        Enum.any?(rules, fn rule ->
          rule["Name"] == key and
            (rule["Values"] in [nil, []] or value in rule["Values"]) and
            (rule["MaxBytes"] == 0 or byte_size(value) <= rule["MaxBytes"])
        end)
      end) and
      Enum.all?(rules, &(&1["Optional"] or &1["Name"] in keys))
  rescue
    _invalid -> false
  end
end
