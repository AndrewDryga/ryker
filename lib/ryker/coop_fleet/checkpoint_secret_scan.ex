defmodule Ryker.CoopFleet.CheckpointSecretScan do
  @moduledoc false

  @markers [
    "-----BEGIN PRIVATE KEY-----",
    "-----BEGIN RSA PRIVATE KEY-----",
    "-----BEGIN EC PRIVATE KEY-----",
    "-----BEGIN OPENSSH PRIVATE KEY-----"
  ]
  @patterns [
    {~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/, ~r/\bxox[baprs]-[A-Za-z0-9-]*\z/},
    {~r/\bxapp-[A-Za-z0-9-]{10,}\b/, ~r/\bxapp-[A-Za-z0-9-]*\z/},
    {~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/, ~r/\bgh[pousr]_[A-Za-z0-9]*\z/},
    {~r/\bAKIA[A-Z0-9]{16}\b/, nil},
    {~r/\bemk-[A-Za-z0-9_-]{10,}\b/, ~r/\bemk-[A-Za-z0-9_-]*\z/}
  ]

  # The values arrive sealed (`Ryker.Secret`) and are opened only here.
  def new(%Ryker.Secret{value: secrets}) when is_list(secrets) do
    if Enum.all?(secrets, &(is_binary(&1) and byte_size(&1) >= 8)) do
      literals = secrets ++ @markers

      {:ok,
       %{
         literals: literals,
         overlap: Enum.max(Enum.map(literals, &byte_size/1)) - 1,
         tail: "",
         patterns:
           Enum.map(@patterns, fn {pattern, pending} ->
             # A chunk ending is not a word boundary. Finalization separately uses
             # the original pattern at the actual end of the member.
             {pattern, Regex.compile!(Regex.source(pattern) <> "(?=[\\s\\S])"), pending, ""}
           end)
       }}
    else
      {:error, :secret}
    end
  end

  def new(_), do: {:error, :secret_configuration}

  def feed(state, bytes) do
    combined = state.tail <> bytes

    if Enum.any?(state.literals, &(:binary.match(combined, &1) != :nomatch)) do
      {:error, :secret}
    else
      with {:ok, patterns} <- scan_patterns(state.patterns, bytes) do
        {:ok, %{state | patterns: Enum.reverse(patterns), tail: last(combined, state.overlap)}}
      end
    end
  end

  defp scan_patterns(patterns, bytes) do
    Enum.reduce_while(patterns, {:ok, []}, fn {pattern, streaming, pending, tail}, {:ok, acc} ->
      text = tail <> bytes

      if Regex.match?(streaming, text),
        do: {:halt, {:error, :secret}},
        else: {:cont, {:ok, [{pattern, streaming, pending, pending_tail(pending, text)} | acc]}}
    end)
  end

  defp pending_tail(pending, text) do
    # Preserve an unfinished token, not its unbounded run of characters.
    # All variable-length patterns saturate by 20 characters; retaining
    # the first 40 and the final character preserves their word boundary.
    case pending && Regex.run(pending, text) do
      [token] when byte_size(token) > 64 ->
        binary_part(token, 0, 40) <> binary_part(token, byte_size(token) - 1, 1)

      [token] ->
        :binary.copy(token)

      _ when byte_size(text) <= 64 ->
        :binary.copy(text)

      _ ->
        "_" <> last(text, 64)
    end
  end

  def finish(state) do
    if Enum.any?(state.patterns, fn {pattern, _, _, tail} -> Regex.match?(pattern, tail) end),
      do: {:error, :secret},
      else: :ok
  end

  defp last(bytes, maximum) do
    :binary.copy(
      binary_part(bytes, max(0, byte_size(bytes) - maximum), min(byte_size(bytes), maximum))
    )
  end
end
