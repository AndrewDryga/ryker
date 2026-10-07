defmodule Ryker.CoopFleet.Bodies do
  @moduledoc false

  alias Ryker.{CanonicalJSON, Defaults, Repo}
  alias Ryker.CoopFleet.{BodyCrypto, Command, CommandQuery, ControlPlane, Protocol}
  alias Ryker.Crypto

  @chunk_bytes 256 * 1_024
  # A worker could upload any size it declared, for any command, up to 2^63
  # bytes (2026-10-04 review). Ryker reads documents and artifacts back with an
  # 8 MiB limit, so nothing larger is ever used; only a checkpoint bundle, a
  # repository's objects, is bigger.
  @document_bytes 8 * 1_024 * 1_024
  @checkpoint_bytes 10 * 1_024 * 1_024 * 1_024

  # One immutable file in each direction per command. No byte arrays in polls,
  # and no acknowledgement until both file contents and directory are durable.
  def prepare_request(%{"body" => body} = request, root, command_id, key) do
    bytes = CanonicalJSON.encode!(body)

    if byte_size(bytes) <= @chunk_bytes do
      {:ok, request}
    else
      reference = %{"byte_size" => byte_size(bytes), "sha256" => Crypto.sha256_hex(bytes)}

      with :ok <- ensure_request(root, command_id, reference, bytes, key) do
        {:ok, request |> Map.delete("body") |> Map.put("body_ref", reference)}
      end
    end
  end

  def prepare_request(%{"body_ref" => reference} = request, root, id, _key) do
    with {:ok, _, ^reference} <- fetch(root, id, :request, reference), do: {:ok, request}
  end

  def prepare_request(request, _root, _command_id, _key), do: {:ok, request}

  defp ensure_request(root, id, reference, bytes, key) do
    case fetch(root, id, :request) do
      {:ok, _path, ^reference} -> :ok
      {:ok, _path, _other} -> {:error, :body_conflict}
      {:error, _} -> put(root, id, :request, reference, [bytes], key)
    end
  end

  def authorize(certificate, command_id) do
    with {:ok, worker_id} <- ControlPlane.authenticate_certificate(certificate),
         {:ok, command_id} <- Ecto.UUID.cast(command_id) do
      case authorized_command(worker_id, command_id, Repo.now!()) do
        %Command{} = command -> {:ok, command}
        nil -> {:error, :body_not_authorized}
      end
    else
      _ -> {:error, :body_not_authorized}
    end
  end

  defp authorized_command(worker_id, command_id, now),
    do: Repo.one(CommandQuery.uploadable(worker_id, command_id, now))

  defdelegate reference?(reference), to: Protocol, as: :body_reference?

  @doc "The most a worker may upload as the response body of `command`."
  @spec response_allowance(Command.t()) :: pos_integer()
  def response_allowance(%Command{kind: "get_checkpoint_bundle"}), do: @checkpoint_bytes
  def response_allowance(%Command{}), do: @document_bytes

  @doc """
  Whether the volume under `root` keeps its reserve after `bytes` more. A
  volume that cannot be measured is not refused for that.
  """
  @spec room?(String.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def room?(root, bytes, reserve \\ Defaults.fetch!(:retention).storage_reserve_bytes) do
    case available_bytes(root) do
      {:ok, available} -> available - bytes >= reserve
      :unknown -> true
    end
  end

  # POSIX `df -P` reports 1024-byte blocks; the fourth column is what is free.
  defp available_bytes(root) do
    with {:ok, existing} <- existing_directory(root),
         {output, 0} <- System.cmd("df", ["-Pk", existing], stderr_to_stdout: true),
         [_header, line | _rest] <- String.split(output, "\n", trim: true),
         [_filesystem, _blocks, _used, available | _rest] <- String.split(line),
         {kilobytes, ""} <- Integer.parse(available) do
      {:ok, kilobytes * 1_024}
    else
      _unknown -> :unknown
    end
  rescue
    _error in ErlangError -> :unknown
  end

  # The body root is made on first use; until then its parent holds it.
  defp existing_directory(path) do
    cond do
      File.dir?(path) -> {:ok, path}
      Path.dirname(path) == path -> :error
      true -> existing_directory(Path.dirname(path))
    end
  end

  def prune_orphans(nil), do: :ok

  def prune_orphans(root) do
    with true <- is_binary(root) and Path.type(root) == :absolute and root != "/",
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         {:ok, names} <- File.ls(root) do
      cutoff = System.os_time(:second) - 86_400

      Enum.reduce_while(names, :ok, fn name, :ok ->
        prune_orphan(root, name, cutoff)
      end)
    else
      {:error, :enoent} -> :ok
      _ -> {:error, :body_storage_unavailable}
    end
  end

  defp prune_orphan(root, name, cutoff) do
    path = Path.join(root, name)

    with {:ok, ^name} <- Ecto.UUID.cast(name),
         {:ok, %File.Stat{type: :directory, mtime: modified}} when modified < cutoff <-
           File.lstat(path, time: :posix),
         false <- Repo.exists?(CommandQuery.by_id(name)) do
      # A command is committed before any writer starts. Its row remains
      # while a checkpoint needs its body; UUIDs are never reused. Removing
      # an orphan cannot authorize an in-flight upload to publish or ACK.
      case File.rm_rf(path) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason, _} -> {:halt, {:error, reason}}
      end
    else
      _ -> {:cont, :ok}
    end
  end

  def put(root, command_id, direction, reference, chunks, key) do
    writer = &write_request_chunks(&1, &2, chunks, reference)

    case store(root, command_id, direction, reference, key, writer) do
      {:ok, :stored} -> :ok
      error -> error
    end
  end

  defp write_request_chunks(file, cipher, chunks, reference) do
    with :ok <- write_chunks(file, cipher, chunks, reference), do: {:ok, :stored}
  end

  def receive_response(root, command_id, reference, certificate, conn, key) do
    store(root, command_id, :response, reference, key, fn file, cipher ->
      with {:ok, conn} <-
             read_chunks(conn, file, cipher, reference, 0, :crypto.hash_init(:sha256)),
           {:ok, _command} <- authorize(certificate, command_id) do
        {:ok, conn}
      end
    end)
  end

  defp store(root, command_id, direction, reference, key, write) do
    with true <- reference?(reference),
         {:ok, command_id} <- Ecto.UUID.cast(command_id),
         {:ok, directory} <- directory(root, command_id),
         {:ok, name} <- direction_name(direction),
         {:ok, cipher} <- BodyCrypto.start(key, binding(command_id, name, reference)) do
      temporary = Path.join(directory, ".#{name}-#{Ecto.UUID.generate()}")

      try do
        with :ok <- private_directory(temporary),
             {:ok, file} <-
               File.open(Path.join(temporary, "data"), [:write, :binary, :exclusive, :raw]) do
          result =
            try do
              with :ok <- File.chmod(Path.join(temporary, "data"), 0o600),
                   {:ok, value} <- write.(file, cipher),
                   :ok <- :file.sync(file) do
                {:ok, value}
              end
            after
              File.close(file)
            end

          with {:ok, value} <- result,
               :ok <-
                 write_receipt(temporary, %{
                   "body_ref" => reference,
                   "encryption" => BodyCrypto.finish(cipher)
                 }),
               :ok <- sync_directory(temporary),
               {:ok, publication} <- publish(temporary, Path.join(directory, name), reference),
               :ok <- verify_replay(publication, root, command_id, direction, reference, key),
               :ok <- sync_directory(directory) do
            {:ok, value}
          end
        end
      after
        File.rm_rf(temporary)
      end
    else
      false -> {:error, :invalid_body_reference}
      :error -> {:error, :invalid_body_command}
      error -> error
    end
  end

  def fetch(root, command_id, direction, reference \\ nil) do
    with {:ok, command_id} <- Ecto.UUID.cast(command_id),
         true <- is_binary(root) and Path.type(root) == :absolute,
         {:ok, name} <- direction_name(direction),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(root),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(Path.join(root, command_id)),
         path = Path.join([root, command_id, name]),
         {:ok, identity, _encryption} <- identity(path),
         true <- is_nil(reference) or identity == reference do
      {:ok, %{root: root, command_id: command_id, direction: direction, reference: identity},
       identity}
    else
      _ -> {:error, :body_not_available}
    end
  end

  # Authenticate the complete immutable file before exposing plaintext. All
  # passes use this same descriptor; a path replacement cannot change the input.
  # The callback may enumerate stream.() repeatedly, but never concurrently.
  def with_stream(body, key, consume) do
    with {:ok, ^body, _} <- fetch(body.root, body.command_id, body.direction, body.reference),
         {:ok, name} <- direction_name(body.direction),
         path = Path.join([body.root, body.command_id, name]),
         {:ok, reference, encryption} <- identity(path),
         true <- reference == body.reference,
         {:ok, file} <- File.open(Path.join(path, "data"), [:read, :raw, :binary]) do
      try do
        with {:ok, decryptor} <-
               BodyCrypto.authenticate(
                 key,
                 binding(body.command_id, name, reference),
                 encryption,
                 file_stream(file)
               ) do
          consume.(fn ->
            Stream.resource(
              fn ->
                case :file.position(file, 0) do
                  {:ok, 0} -> :ok
                  {:error, reason} -> raise File.Error, reason: reason, action: "seek worker body"
                end

                decryptor.()
              end,
              fn cipher ->
                case :file.read(file, @chunk_bytes) do
                  {:ok, bytes} -> {[:crypto.crypto_update(cipher, bytes)], cipher}
                  :eof -> {:halt, cipher}
                  {:error, reason} -> raise File.Error, reason: reason, action: "read worker body"
                end
              end,
              fn _ -> :ok end
            )
          end)
        end
      after
        File.close(file)
      end
    else
      _ -> {:error, :body_not_available}
    end
  rescue
    _error in File.Error -> {:error, :body_storage_unavailable}
  end

  def read(body, key, maximum_bytes) do
    if body.reference["byte_size"] <= maximum_bytes do
      with_stream(body, key, fn stream ->
        {:ok, stream.() |> Enum.to_list() |> IO.iodata_to_binary()}
      end)
    else
      {:error, :body_too_large}
    end
  end

  defp file_stream(file) do
    Stream.resource(
      fn -> file end,
      fn file ->
        case :file.read(file, @chunk_bytes) do
          {:ok, bytes} -> {[bytes], file}
          :eof -> {:halt, file}
          {:error, reason} -> raise File.Error, reason: reason, action: "read worker body"
        end
      end,
      fn _ -> :ok end
    )
  end

  defp binding(id, direction, reference),
    do: %{"command_id" => id, "direction" => direction, "body_ref" => reference}

  defp directory(root, command_id) when is_binary(root) do
    with true <- Path.type(root) == :absolute,
         {:ok, command_id} <- Ecto.UUID.cast(command_id),
         :ok <- private_directory(root),
         :ok <- private_directory(Path.join(root, command_id)),
         :ok <- sync_directory(Path.dirname(root)),
         :ok <- sync_directory(root) do
      {:ok, Path.join(root, command_id)}
    else
      _ -> {:error, :body_storage_unavailable}
    end
  end

  defp directory(_, _), do: {:error, :body_storage_unavailable}

  defp private_directory(path) do
    with :ok <- File.mkdir_p(path),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(path) do
      File.chmod(path, 0o700)
    else
      _ -> {:error, :body_storage_unavailable}
    end
  end

  defp direction_name(:request), do: {:ok, "request"}
  defp direction_name(:response), do: {:ok, "response"}
  defp direction_name(_), do: {:error, :invalid_body_direction}

  defp read_chunks(conn, file, cipher, reference, size, hash) do
    case Plug.Conn.read_body(conn, length: @chunk_bytes, read_length: @chunk_bytes) do
      {state, bytes, conn} when state in [:ok, :more] ->
        total = size + byte_size(bytes)

        with true <- total <= reference["byte_size"],
             :ok <- :file.write(file, BodyCrypto.encrypt(cipher, bytes)) do
          hash = :crypto.hash_update(hash, bytes)

          finish_response(state, conn, file, cipher, reference, total, hash)
        else
          false -> {:error, :body_size_mismatch}
          error -> error
        end

      error ->
        error
    end
  end

  defp finish_response(:more, conn, file, cipher, reference, size, hash),
    do: read_chunks(conn, file, cipher, reference, size, hash)

  defp finish_response(:ok, conn, _file, _cipher, reference, size, hash) do
    with :ok <- verify_written({size, hash}, reference), do: {:ok, conn}
  end

  defp write_chunks(file, cipher, chunks, reference) do
    chunks
    |> Enum.reduce_while({0, :crypto.hash_init(:sha256)}, fn chunk, state ->
      write_chunk(file, cipher, reference, chunk, state)
    end)
    |> verify_written(reference)
  end

  defp write_chunk(file, cipher, reference, chunk, {size, hash}) do
    total = size + byte_size(chunk)

    with true <- total <= reference["byte_size"],
         :ok <- :file.write(file, BodyCrypto.encrypt(cipher, chunk)) do
      {:cont, {total, :crypto.hash_update(hash, chunk)}}
    else
      false -> {:halt, {:error, :body_size_mismatch}}
      error -> {:halt, error}
    end
  end

  defp verify_written({:error, _} = error, _reference), do: error

  defp verify_written({size, hash}, reference) do
    if %{"byte_size" => size, "sha256" => hex(:crypto.hash_final(hash))} == reference,
      do: :ok,
      else: {:error, :body_identity_mismatch}
  end

  defp publish(temporary, path, reference) do
    case File.rename(temporary, path) do
      :ok ->
        {:ok, :created}

      {:error, reason} when reason in [:eexist, :enotempty] ->
        case identity(path) do
          {:ok, ^reference, _encryption} -> {:ok, :existing}
          _ -> {:error, :body_conflict}
        end

      error ->
        error
    end
  end

  defp verify_replay(:created, _root, _id, _direction, _reference, _key), do: :ok

  defp verify_replay(:existing, root, id, direction, reference, key) do
    with {:ok, body, ^reference} <- fetch(root, id, direction, reference),
         do: with_stream(body, key, fn _stream -> :ok end)
  end

  defp identity(path) do
    with {:ok, %File.Stat{type: :directory}} <- File.lstat(path),
         receipt = Path.join(path, "receipt"),
         {:ok, %File.Stat{type: :regular, size: size}} when size <= 512 <- File.lstat(receipt),
         {:ok, bytes} <- File.read(receipt),
         {:ok, %{"body_ref" => reference, "encryption" => encryption}} <- Jason.decode(bytes),
         true <- reference?(reference),
         {:ok, %File.Stat{type: :regular, size: data_size}} <- File.lstat(Path.join(path, "data")),
         true <- data_size == reference["byte_size"] do
      {:ok, reference, encryption}
    else
      _ -> {:error, :body_not_available}
    end
  end

  defp write_receipt(directory, reference) do
    path = Path.join(directory, "receipt")

    with {:ok, file} <- File.open(path, [:write, :binary, :exclusive, :raw]) do
      try do
        with :ok <- File.chmod(path, 0o600),
             :ok <- :file.write(file, CanonicalJSON.encode!(reference)),
             do: :file.sync(file)
      after
        File.close(file)
      end
    end
  end

  defp sync_directory(path) do
    with {:ok, file} <- :file.open(String.to_charlist(path), [:read, :raw, :directory]) do
      try do
        :file.sync(file)
      after
        :file.close(file)
      end
    end
  end

  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
