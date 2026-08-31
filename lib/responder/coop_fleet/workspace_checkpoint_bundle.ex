defmodule Responder.CoopFleet.WorkspaceCheckpointBundle do
  @moduledoc false

  alias Responder.CoopFleet.WorkspaceCheckpoint

  @block_bytes 512
  @credential_markers [
    "-----BEGIN PRIVATE KEY-----",
    "-----BEGIN RSA PRIVATE KEY-----",
    "-----BEGIN EC PRIVATE KEY-----",
    "-----BEGIN OPENSSH PRIVATE KEY-----"
  ]
  @credential_patterns [
    ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/,
    ~r/\bxapp-[A-Za-z0-9-]{10,}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/,
    ~r/\bAKIA[A-Z0-9]{16}\b/,
    ~r/\bemk-[A-Za-z0-9_-]{10,}\b/
  ]

  @spec validate(map(), binary(), [binary()]) :: {:ok, map()} | {:error, term()}
  def validate(checkpoint, bundle, secrets \\ []) do
    with {:ok, checkpoint} <- WorkspaceCheckpoint.validate(checkpoint),
         true <- is_binary(bundle),
         true <- byte_size(bundle) == checkpoint["bundle"]["byte_size"],
         true <- digest(bundle) == checkpoint["bundle"]["sha256"],
         {:ok, members} <- parse_tar(bundle),
         {:ok, manifest, content_members} <- manifest(members),
         :ok <- WorkspaceCheckpoint.validate_pair(checkpoint, manifest),
         :ok <- exact_members(manifest, content_members),
         :ok <- secrets(content_members, secrets) do
      {:ok, manifest}
    else
      false -> error(:identity)
      {:error, _reason} = result -> result
    end
  end

  defp manifest([%{name: "manifest.json", mode: 0o644, body: body} | members]) do
    case WorkspaceCheckpoint.decode_bundle_manifest(body) do
      {:ok, manifest} -> {:ok, manifest, members}
      {:error, _reason} = error -> error
    end
  end

  defp manifest(_members), do: error(:manifest)

  defp exact_members(manifest, members) do
    expected =
      [entry(manifest["tracked_patch"], 0o644)] ++
        Enum.map(manifest["untracked_files"], &entry(&1, &1["mode"])) ++
        Enum.map(manifest["task_projection"]["files"], &entry(&1, &1["mode"])) ++
        if(manifest["gate_receipt"], do: [entry(manifest["gate_receipt"], 0o644)], else: [])

    if length(expected) == length(members) and
         Enum.zip(expected, members)
         |> Enum.all?(fn {wanted, actual} -> member_matches?(wanted, actual) end),
       do: :ok,
       else: error(:members)
  end

  defp entry(value, mode) do
    %{name: value["entry"], mode: mode, size: value["byte_size"], sha256: value["sha256"]}
  end

  defp member_matches?(expected, actual) do
    expected.name == actual.name and expected.mode == actual.mode and expected.size == actual.size and
      expected.sha256 == digest(actual.body)
  end

  defp secrets(members, configured) when is_list(configured) do
    safe_configured? =
      Enum.all?(configured, &(is_binary(&1) and byte_size(&1) >= 8))

    exposed? =
      Enum.any?(members, fn member ->
        Enum.any?(configured, &(:binary.match(member.body, &1) != :nomatch)) or
          Enum.any?(@credential_markers, &(:binary.match(member.body, &1) != :nomatch)) or
          (String.valid?(member.body) and
             Enum.any?(@credential_patterns, &Regex.match?(&1, member.body)))
      end)

    if safe_configured? and not exposed?, do: :ok, else: error(:secret)
  end

  defp secrets(_members, _configured), do: error(:secret_configuration)

  defp parse_tar(bundle), do: parse_tar(bundle, [])

  defp parse_tar(<<header::binary-size(@block_bytes), rest::binary>>, members) do
    if header == :binary.copy(<<0>>, @block_bytes) do
      if byte_size(rest) >= @block_bytes and rem(byte_size(rest), @block_bytes) == 0 and
           rest == :binary.copy(<<0>>, byte_size(rest)),
         do: {:ok, Enum.reverse(members)},
         else: error(:terminator)
    else
      with {:ok, metadata} <- parse_header(header),
           padding_bytes <- padding_size(metadata.size),
           true <- byte_size(rest) >= padded_size(metadata.size),
           <<body::binary-size(metadata.size), padding::binary-size(padding_bytes), tail::binary>> <-
             rest,
           true <- padding == :binary.copy(<<0>>, byte_size(padding)) do
        parse_tar(tail, [Map.put(metadata, :body, body) | members])
      else
        false -> error(:member_length)
        {:error, _reason} = error -> error
        _invalid -> error(:member)
      end
    end
  end

  defp parse_tar(_bundle, _members), do: error(:tar)

  defp parse_header(header) do
    with <<name::binary-size(100), mode::binary-size(8), uid::binary-size(8), gid::binary-size(8),
           size::binary-size(12), mtime::binary-size(12), checksum::binary-size(8),
           type::binary-size(1), linkname::binary-size(100), magic::binary-size(6),
           version::binary-size(2), uname::binary-size(32), gname::binary-size(32),
           devmajor::binary-size(8), devminor::binary-size(8), prefix::binary-size(155),
           _padding::binary-size(12)>> <- header,
         {:ok, numbers} <-
           header_numbers([mode, uid, gid, size, mtime, checksum, devmajor, devminor]),
         [mode, uid, gid, size, mtime, stored_checksum, devmajor, devminor] <- numbers,
         true <-
           valid_ustar_header?(
             header,
             stored_checksum,
             {type, magic, version},
             {uid, gid, mtime, devmajor, devminor},
             [linkname, uname, gname, prefix]
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

  defp valid_ustar_header?(
         header,
         stored_checksum,
         identity,
         numeric_identity,
         text_fields
       ) do
    checksum(header) == stored_checksum and
      identity == {"0", "ustar\0", "00"} and
      numeric_identity == {0, 0, 0, 0, 0} and
      Enum.all?(text_fields, &blank?/1)
  end

  defp valid_member_header?(name, mode, size) do
    name != "" and String.valid?(name) and byte_size(name) <= 100 and
      mode in [0o644, 0o755] and size >= 0 and
      size <= WorkspaceCheckpoint.maximum_bundle_bytes()
  end

  defp octal(value) do
    trimmed = value |> :binary.replace(<<0>>, "", [:global]) |> String.trim()

    case Integer.parse(if(trimmed == "", do: "0", else: trimmed), 8) do
      {number, ""} when number >= 0 -> {:ok, number}
      _invalid -> error(:number)
    end
  end

  defp checksum(header) do
    checksum_header = binary_part(header, 0, 148) <> "        " <> binary_part(header, 156, 356)
    checksum_header |> :binary.bin_to_list() |> Enum.sum()
  end

  defp trim_nul(value), do: value |> :binary.split(<<0>>) |> hd()
  defp blank?(value), do: trim_nul(value) == ""
  defp padding_size(size), do: rem(@block_bytes - rem(size, @block_bytes), @block_bytes)
  defp padded_size(size), do: size + padding_size(size)
  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp error(reason), do: {:error, {:invalid_workspace_checkpoint_bundle, reason}}
end
