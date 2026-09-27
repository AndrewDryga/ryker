defmodule Ryker.LocalRouting.Endpoint do
  @moduledoc """
  Where the local routing model answers: an OpenAI-compatible base address,
  such as `http://host.docker.internal:11434/v1` for Ollama on the Mac that
  runs Ryker's Compose install. Requests go to its `/chat/completions`.

  Every routing prompt sent there holds a person's message and the
  conversation around it. Like `Ryker.Delivery.JSONClient`, which keeps plain
  http for loopback, plain http is accepted only where it never crosses an
  untrusted network: this machine (`localhost`, or the Docker host as
  `host.docker.internal` or `host.containers.internal`), a private address
  (10/8, 172.16/12, 192.168/16, IPv6 fc00::/7), a Tailscale address
  (100.64/10), or a name under `.local`, `.lan`, `.internal`, `.home.arpa` or
  `.ts.net`. Anywhere else needs https. An address never carries a user
  name, a query or a fragment.
  """

  @maximum_bytes 2_048
  @local_names ~w(localhost host.docker.internal host.containers.internal)
  @local_suffixes ~w(.localhost .local .lan .internal .home.arpa .ts.net)

  @spec check(term()) :: :ok | {:error, :format | :insecure}
  def check(url) when is_binary(url) and byte_size(url) in 1..@maximum_bytes do
    with true <- String.valid?(url) and Regex.match?(~r/\A\S+\z/, url),
         %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}
         when scheme in ["http", "https"] and is_binary(host) and host != "" <- URI.parse(url) do
      if scheme == "https" or nearby?(String.downcase(host)),
        do: :ok,
        else: {:error, :insecure}
    else
      _invalid -> {:error, :format}
    end
  end

  def check(_url), do: {:error, :format}

  @doc "The chat completions address under a saved endpoint."
  @spec completions(String.t()) :: String.t()
  def completions(endpoint), do: String.trim_trailing(endpoint, "/") <> "/chat/completions"

  defp nearby?(host) when host in @local_names, do: true

  defp nearby?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> private_address?(address)
      {:error, _not_an_address} -> String.ends_with?(host, @local_suffixes)
    end
  end

  defp private_address?({127, _, _, _}), do: true
  defp private_address?({10, _, _, _}), do: true
  defp private_address?({172, second, _, _}) when second in 16..31, do: true
  defp private_address?({192, 168, _, _}), do: true
  defp private_address?({100, second, _, _}) when second in 64..127, do: true
  defp private_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_address?({first, _, _, _, _, _, _, _}) when first in 0xFC00..0xFDFF, do: true
  defp private_address?(_address), do: false
end
