defmodule Ryker.GitHub.Client.JobLog do
  @moduledoc "Bounded, redacted job-log evidence from GitHub's authenticated signed download."
  alias Ryker.GitHub.Client.Transport
  alias Ryker.InspectionRedactor
  alias Ryker.Text

  @maximum_bytes 2 * 1_024 * 1_024
  @excerpt_bytes 24 * 1_024
  @excerpt_lines 120

  @doc "Reads a job already returned by the exact run-attempt lookup; URLs never come from the model."
  def read(client, repository, job_id) do
    with {:ok, redirect} <-
           Transport.request(
             client,
             :get,
             "/repos/#{repository}/actions/jobs/#{job_id}/logs",
             nil
           ),
         {:ok, url} <- location(redirect),
         {:ok, response} <- Transport.download(client, url, @maximum_bytes) do
      excerpt(response)
    else
      {:error, {:http_status, status}} -> unavailable("http_error", status)
      {:error, {:delivery_protocol_error, :response_too_large}} -> unavailable("too_large")
      {:error, :untrusted_download} -> unavailable("untrusted_download")
      {:error, _reason} -> unavailable("download_failed")
    end
  rescue
    _error -> unavailable("download_failed")
  end

  defp location(%{status: 302, headers: headers}) when is_list(headers) do
    url =
      Enum.find_value(headers, fn {name, value} ->
        if String.downcase(name) == "location", do: value
      end)

    if trusted_url?(url), do: {:ok, url}, else: {:error, :untrusted_download}
  end

  defp location(%{status: status}) when is_integer(status),
    do: {:error, {:http_status, status}}

  defp location(_invalid), do: {:error, :invalid_redirect}

  defp trusted_url?(url) when is_binary(url) and byte_size(url) <= 4_096 do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil, fragment: nil}
      when is_binary(host) ->
        host = String.downcase(host)

        String.ends_with?(host, ".blob.core.windows.net") or
          String.ends_with?(host, ".actions.githubusercontent.com")

      _invalid ->
        false
    end
  end

  defp trusted_url?(_invalid), do: false

  defp excerpt(%{status: 200, body: body})
       when is_binary(body) and byte_size(body) <= @maximum_bytes do
    if String.valid?(body) do
      redacted = InspectionRedactor.redact(body, InspectionRedactor.configured_secrets())

      text =
        redacted
        |> String.split("\n")
        |> Enum.take(-@excerpt_lines)
        |> Enum.join("\n")
        |> String.reverse()
        |> Text.bytes(@excerpt_bytes)
        |> String.reverse()

      %{
        "state" => "available",
        "text" => text,
        "redacted" => redacted != body,
        "truncated" => text != redacted
      }
    else
      unavailable("invalid_text")
    end
  end

  defp excerpt(%{status: status}) when is_integer(status),
    do: unavailable("http_error", status)

  defp excerpt(_invalid), do: unavailable("invalid_response")

  defp unavailable(reason, status \\ nil),
    do: %{"state" => "unavailable", "reason" => reason, "http_status" => status}
end
