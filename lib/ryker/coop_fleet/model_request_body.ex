defmodule Ryker.CoopFleet.ModelRequestBody do
  @moduledoc false
  import Bitwise

  # Codex compresses ChatGPT inference requests before the worker forwards them.
  # The controller checks the decoded model and forwards the original HTTP bytes.
  def decode(headers, body, limit) when byte_size(body) <= limit do
    case Enum.map(headers, &String.downcase/1) do
      encoding when encoding in [[], ["identity"]] -> {:ok, body}
      ["zstd"] -> decompress(body, limit)
      _unsupported -> :error
    end
  end

  def decode(_headers, _body, _limit), do: :error

  defp decompress(body, limit) do
    with {:ok, %{frameType: :ZSTD_frame, dictID: 0} = header} <- :zstd.get_frame_header(body),
         true <- header.windowSize <= limit,
         true <- header.frameContentSize == :undefined or header.frameContentSize <= limit,
         <<_header::binary-size(header.headerSize), blocks::binary>> <- body,
         true <- complete_frame?(blocks, if(header.checksumFlag, do: 4, else: 0)) do
      {:ok, context} = :zstd.context(:decompress, %{windowLogMax: 25})

      try do
        inflate(context, body, limit, [])
      after
        :zstd.close(context)
      end
    else
      _invalid -> :error
    end
  rescue
    ErlangError -> :error
    ArgumentError -> :error
  end

  # OTP's streaming decoder can return partial output on a truncated frame.
  # Require one complete frame before treating that output as a model request.
  defp complete_frame?(<<tag::little-24, rest::binary>>, checksum) do
    type = band(bsr(tag, 1), 3)
    size = bsr(tag, 3)
    stored = if type == 1, do: 1, else: size

    with true <- type != 3 and size <= 131_072,
         <<_block::binary-size(stored), tail::binary>> <- rest do
      if band(tag, 1) == 1, do: byte_size(tail) == checksum, else: complete_frame?(tail, checksum)
    else
      _invalid -> false
    end
  end

  defp complete_frame?(_incomplete, _checksum), do: false

  defp inflate(context, input, remaining, acc) do
    case :zstd.stream(context, input) do
      {:continue, rest, chunk} when byte_size(chunk) <= remaining ->
        inflate(context, rest, remaining - byte_size(chunk), [chunk | acc])

      {:continue, chunk} when byte_size(chunk) <= remaining ->
        {:ok, [chunk | acc] |> Enum.reverse() |> IO.iodata_to_binary()}

      _over_limit ->
        :error
    end
  end
end
