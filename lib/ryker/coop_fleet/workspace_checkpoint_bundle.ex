defmodule Ryker.CoopFleet.WorkspaceCheckpointBundle do
  @moduledoc false

  alias Ryker.CoopFleet.{CheckpointSecretScan, WorkspaceCheckpoint}

  @spec validate(map(), binary(), [binary()]) :: {:ok, map()} | {:error, term()}
  def validate(checkpoint, bundle, secrets \\ []) do
    if is_binary(bundle),
      do: validate_stream(checkpoint, [bundle], secrets),
      else: error(:identity)
  end

  def validate_stream(checkpoint, chunks, secrets \\ []) do
    with {:ok, checkpoint} <- WorkspaceCheckpoint.validate(checkpoint),
         {:ok, scanner} <- new_scanner(secrets) do
      state = %{
        phase: {:header, ""},
        manifest: nil,
        expected: [:manifest],
        checkpoint: checkpoint,
        scanner: scanner,
        bytes: 0,
        hash: :crypto.hash_init(:sha256)
      }

      chunks |> Enum.reduce_while({:ok, state}, &consume_chunk/2) |> finish_validation()
    end
  end

  defp consume_chunk(bytes, {:ok, state}) do
    state = %{
      state
      | bytes: state.bytes + byte_size(bytes),
        hash: :crypto.hash_update(state.hash, bytes)
    }

    result =
      if state.bytes <= state.checkpoint["bundle"]["byte_size"],
        do: feed(state, bytes),
        else: error(:identity)

    case result do
      {:ok, state} -> {:cont, {:ok, state}}
      error -> {:halt, error}
    end
  end

  defp finish_validation(
         {:ok, %{phase: {:terminator, size}, expected: [], manifest: manifest} = state}
       )
       when size >= 1_024 and rem(size, 512) == 0 and is_map(manifest) do
    if state.bytes == state.checkpoint["bundle"]["byte_size"] and
         hex(:crypto.hash_final(state.hash)) == state.checkpoint["bundle"]["sha256"],
       do: {:ok, manifest},
       else: error(:identity)
  end

  defp finish_validation({:error, _} = error), do: error
  defp finish_validation({:ok, %{phase: {:body, _, _, _, _, _}}}), do: error(:member_length)
  defp finish_validation({:ok, %{phase: {:padding, _}}}), do: error(:member_length)
  defp finish_validation({:ok, %{phase: {:terminator, _}}}), do: error(:terminator)
  defp finish_validation(_), do: error(:tar)

  defp feed(%{phase: {:header, previous}} = state, bytes) do
    needed = 512 - byte_size(previous)

    if byte_size(bytes) < needed do
      {:ok, %{state | phase: {:header, previous <> bytes}}}
    else
      <<part::binary-size(needed), rest::binary>> = bytes
      feed_header(state, previous <> part, rest)
    end
  end

  defp feed(%{phase: {:body, member, left, hash, scan, parts}} = state, bytes) do
    count = min(left, byte_size(bytes))
    <<part::binary-size(count), rest::binary>> = bytes
    hash = :crypto.hash_update(hash, part)
    parts = if member == :manifest and part != "", do: [:binary.copy(part) | parts], else: parts

    case CheckpointSecretScan.feed(scan, part) do
      {:ok, scan} ->
        advance_body(%{state | phase: {:body, member, left - count, hash, scan, parts}}, rest)

      {:error, reason} ->
        error(reason)
    end
  end

  defp feed(%{phase: {:padding, left}} = state, bytes) do
    count = min(left, byte_size(bytes))
    <<padding::binary-size(count), rest::binary>> = bytes

    if padding == :binary.copy(<<0>>, count) do
      if count == left,
        do: feed(%{state | phase: {:header, ""}}, rest),
        else: {:ok, %{state | phase: {:padding, left - count}}}
    else
      error(:member_length)
    end
  end

  defp feed(%{phase: {:terminator, size}} = state, bytes) do
    if bytes == :binary.copy(<<0>>, byte_size(bytes)),
      do: {:ok, %{state | phase: {:terminator, size + byte_size(bytes)}}},
      else: error(:terminator)
  end

  defp feed_header(state, header, rest) do
    if header == :binary.copy(<<0>>, 512) do
      if state.expected == [],
        do: feed(%{state | phase: {:terminator, 512}}, rest),
        else: error(:members)
    else
      with {:ok, metadata} <- parse_header(header),
           {:ok, state} <- start_member(state, metadata) do
        feed(state, rest)
      end
    end
  end

  defp advance_body(%{phase: {:body, member, 0, hash, scan, parts}} = state, rest) do
    with {:ok, state} <- finish_member(state, member, hash, scan, parts), do: feed(state, rest)
  end

  defp advance_body(state, _rest), do: {:ok, state}

  defp start_member(%{expected: [:manifest]} = state, %{
         name: "manifest.json",
         mode: 0o644,
         size: size
       })
       when size in 1..1_048_576,
       do:
         {:ok,
          %{
            state
            | phase: {:body, :manifest, size, :crypto.hash_init(:sha256), state.scanner, []},
              expected: [padding_size(size)]
          }}

  defp start_member(%{expected: [wanted | remaining]} = state, actual) when is_map(wanted) do
    if Map.take(wanted, [:name, :mode, :size]) == actual do
      {:ok,
       %{
         state
         | phase: {:body, wanted, wanted.size, :crypto.hash_init(:sha256), state.scanner, []},
           expected: remaining
       }}
    else
      error(:members)
    end
  end

  defp start_member(%{expected: [:manifest]}, _), do: error(:manifest)
  defp start_member(_, _), do: error(:members)

  defp finish_member(state, :manifest, _hash, scan, parts) do
    with :ok <- scan_result(CheckpointSecretScan.finish(scan)),
         {:ok, manifest} <-
           WorkspaceCheckpoint.decode_bundle_manifest(
             parts
             |> Enum.reverse()
             |> IO.iodata_to_binary()
           ),
         :ok <- WorkspaceCheckpoint.validate_pair(state.checkpoint, manifest) do
      [padding] = state.expected

      {:ok,
       %{
         state
         | manifest: manifest,
           expected: expected_members(manifest),
           phase: {:padding, padding}
       }}
    end
  end

  defp finish_member(state, member, hash, scan, _parts) do
    with :ok <- scan_result(CheckpointSecretScan.finish(scan)),
         true <- hex(:crypto.hash_final(hash)) == member.sha256 do
      {:ok, %{state | phase: {:padding, padding_size(member.size)}}}
    else
      false -> error(:members)
      error -> error
    end
  end

  defp scan_result(:ok), do: :ok
  defp scan_result({:error, reason}), do: error(reason)

  defp new_scanner(secrets) do
    case CheckpointSecretScan.new(secrets) do
      {:ok, scanner} -> {:ok, scanner}
      {:error, reason} -> error(reason)
    end
  end

  defp expected_members(manifest) do
    [entry(manifest["repository"], 0o644)] ++
      Enum.map(manifest["untracked_files"], &entry(&1, &1["mode"])) ++
      Enum.map(manifest["task_projection"]["files"], &entry(&1, &1["mode"])) ++
      if(manifest["gate_receipt"], do: [entry(manifest["gate_receipt"], 0o644)], else: [])
  end

  defp entry(value, mode) do
    %{name: value["entry"], mode: mode, size: value["byte_size"], sha256: value["sha256"]}
  end

  defp parse_header(header) do
    with <<name::binary-size(100), mode::binary-size(8), uid::binary-size(8), gid::binary-size(8),
           size::binary-size(12), mtime::binary-size(12), checksum::binary-size(8),
           type::binary-size(1), linkname::binary-size(100), magic::binary-size(6),
           version::binary-size(2), uname::binary-size(32), gname::binary-size(32),
           devmajor::binary-size(8), devminor::binary-size(8), prefix::binary-size(155),
           padding::binary-size(12)>> <- header,
         {:ok, size} <- tar_size(size),
         {:ok, numbers} <-
           header_numbers([mode, uid, gid, mtime, checksum, devmajor, devminor]),
         [mode, uid, gid, mtime, stored_checksum, devmajor, devminor] <- numbers,
         true <-
           valid_ustar_header?(
             header,
             stored_checksum,
             {type, magic, version},
             {uid, gid, mtime, devmajor, devminor},
             [linkname, uname, gname, prefix, padding]
           ),
         name <- trim_nul(name),
         true <- valid_member_header?(name, mode, size) do
      {:ok, %{name: name, mode: mode, size: size}}
    else
      _invalid -> error(:header)
    end
  end

  defp header_numbers(values) do
    case Enum.map(values, &octal/1) do
      [{:ok, _} | _] = parsed ->
        if Enum.all?(parsed, &match?({:ok, _}, &1)),
          do: {:ok, Enum.map(parsed, fn {:ok, value} -> value end)},
          else: error(:number)

      _invalid ->
        error(:number)
    end
  end

  # Coop writes GNU headers: a regular file, the "ustar " magic and " \0" version.
  defp valid_ustar_header?(header, stored_checksum, identity, numeric_identity, text_fields) do
    checksum(header) == stored_checksum and
      identity == {"0", "ustar ", " \0"} and
      numeric_identity == {0, 0, 0, 0, 0} and
      Enum.all?(text_fields, &blank?/1)
  end

  # GNU uses base-256 only when eleven octal digits cannot represent the size.
  # Accept the exact positive form Go emits, never signed/overflow/extension data.
  defp tar_size(<<128, number::unsigned-big-integer-size(88)>>)
       when number >= 8_589_934_592 and number <= 9_223_372_036_854_775_806,
       do: {:ok, number}

  defp tar_size(value), do: octal(value)

  defp valid_member_header?(name, mode, size) do
    name != "" and String.valid?(name) and byte_size(name) <= 100 and
      mode in [0o644, 0o755] and size >= 0 and
      size <= WorkspaceCheckpoint.maximum_bundle_bytes()
  end

  defp octal(value) do
    with true <- Regex.match?(~r/\A[ \x00]*[0-7]*[ \x00]*\z/, value),
         trimmed = value |> :binary.replace(<<0>>, "", [:global]) |> String.trim(),
         {number, ""} when number >= 0 <- Integer.parse("0" <> trimmed, 8) do
      {:ok, number}
    else
      _invalid -> error(:number)
    end
  end

  defp checksum(header) do
    checksum_header = binary_part(header, 0, 148) <> "        " <> binary_part(header, 156, 356)
    checksum_header |> :binary.bin_to_list() |> Enum.sum()
  end

  defp trim_nul(value), do: value |> :binary.split(<<0>>) |> hd()
  defp blank?(value), do: value == :binary.copy(<<0>>, byte_size(value))
  defp padding_size(size), do: rem(512 - rem(size, 512), 512)
  defp hex(value), do: Base.encode16(value, case: :lower)
  defp error(reason), do: {:error, {:invalid_workspace_checkpoint_bundle, reason}}
end
