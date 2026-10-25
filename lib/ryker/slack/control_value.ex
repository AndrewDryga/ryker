defmodule Ryker.Slack.ControlValue do
  @moduledoc """
  The resource and version a control button carries. Behaviors and schedules
  use an integer revision; memories use their content fingerprint.
  App Home writes it; App Home and the chat interaction handler read it back,
  and each kept its own copy of the reader.
  """
  alias Ryker.Crypto

  @type version :: pos_integer() | String.t()

  @doc "The value for `kind`'s resource `ref` at `version`."
  @spec encode(String.t(), String.t(), version()) :: String.t()
  def encode(kind, ref, version), do: "#{kind}-control:#{ref}:#{version}"

  @doc """
  The resource ref and version a `kind` control's `value` carries: the ref is
  itself `kind:…`. Memory versions are SHA-256 fingerprints; other versions
  are positive integers. Returns `:error` for any other shape.
  """
  @spec decode(term(), String.t()) :: {:ok, String.t(), version()} | :error
  def decode(value, kind) when is_binary(value) do
    prefix = kind <> "-control:"

    {ref_parts, [revision_text]} =
      value |> String.replace_prefix(prefix, "") |> String.split(":") |> Enum.split(-1)

    ref = Enum.join(ref_parts, ":")

    with true <- String.starts_with?(value, prefix) and String.starts_with?(ref, kind <> ":"),
         {:ok, version} <- version(kind, revision_text) do
      {:ok, ref, version}
    else
      _invalid -> :error
    end
  end

  def decode(_value, _kind), do: :error

  defp version("memory", text) do
    if Crypto.sha256_hex?(text), do: {:ok, text}, else: :error
  end

  defp version(_kind, text) do
    case Integer.parse(text) do
      {revision, ""} when revision > 0 -> {:ok, revision}
      _invalid -> :error
    end
  end
end
