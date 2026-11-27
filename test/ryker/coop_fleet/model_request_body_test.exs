defmodule Ryker.CoopFleet.ModelRequestBodyTest do
  use ExUnit.Case, async: true
  alias Ryker.CoopFleet.ModelRequestBody

  @limit 32 * 1024 * 1024

  test "decodes the native client's streaming frame and checks both body size limits" do
    body = String.duplicate("model request ", 25_000)
    frame = compress(body, %{contentSizeFlag: false, checksumFlag: true, windowLog: 16})

    assert {:ok, %{windowSize: window, frameContentSize: :undefined}} =
             :zstd.get_frame_header(frame)

    assert window < byte_size(body) - 1
    assert {:ok, ^body} = ModelRequestBody.decode(["zstd"], frame, @limit)
    assert ModelRequestBody.decode(["zstd"], frame, byte_size(body) - 1) == :error
    assert ModelRequestBody.decode([], body, byte_size(body) - 1) == :error
    assert ModelRequestBody.decode(["zstd"], frame, byte_size(frame) - 1) == :error
  end

  test "incomplete, extra, unsupported and malformed frames are rejected" do
    frame = compress(~s({"model":"gpt-6.1-sol"}), %{checksumFlag: true})

    for size <- 0..(byte_size(frame) - 1) do
      assert ModelRequestBody.decode(["zstd"], binary_part(frame, 0, size), @limit) == :error
    end

    assert ModelRequestBody.decode(["zstd"], frame <> frame, @limit) == :error
    assert ModelRequestBody.decode(["zstd", "identity"], frame, @limit) == :error
    assert ModelRequestBody.decode(["unknown"], frame, @limit) == :error
    assert ModelRequestBody.decode(["zstd"], "invalid", @limit) == :error
  end

  defp compress(body, opts), do: body |> :zstd.compress(opts) |> IO.iodata_to_binary()
end
