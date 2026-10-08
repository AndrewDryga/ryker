defmodule Ryker.CoopFleet.BodiesTest do
  use ExUnit.Case, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.CoopFleet.Bodies

  @key Ryker.Secret.new(:binary.copy(<<7>>, 32))

  setup do
    root = Path.join(System.tmp_dir!(), "coop-bodies-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, command_id: Ecto.UUID.generate()}
  end

  test "a body larger than the former checkpoint cap streams into immutable command custody",
       %{command_id: command_id, root: root} do
    chunk = :binary.copy("b", 256 * 1_024)
    chunks = Stream.repeatedly(fn -> chunk end) |> Stream.take(272)
    hash = Enum.reduce(chunks, :crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))

    reference = %{
      "byte_size" => byte_size(chunk) * 272,
      "sha256" => Base.encode16(:crypto.hash_final(hash), case: :lower)
    }

    assert Bodies.put(root, command_id, :response, reference, chunks, @key) == :ok

    assert {:ok, body, ^reference} =
             Bodies.fetch(root, command_id, :response, reference)

    path = Path.join([root, command_id, "response", "data"])

    assert File.stat!(path).size == 68 * 1_024 * 1_024
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Enum.sort(File.ls!(Path.dirname(path))) == ["data", "receipt"]

    # Heartbeats check the atomic receipt and stat, never reopen a multi-GB payload.
    File.chmod!(path, 0o000)
    assert {:ok, ^body, ^reference} = Bodies.fetch(root, command_id, :response)
    File.chmod!(path, 0o600)

    # A lost upload acknowledgement reuses the exact file. A changed retry never overwrites it.
    receipt = File.read!(Path.join(Path.dirname(path), "receipt"))
    assert Bodies.put(root, command_id, :response, reference, chunks, @key) == :ok
    assert File.read!(Path.join(Path.dirname(path), "receipt")) == receipt

    assert Bodies.with_stream(body, @key, fn stream ->
             for _ <- 1..2 do
               hash =
                 Enum.reduce(
                   stream.(),
                   :crypto.hash_init(:sha256),
                   &:crypto.hash_update(&2, &1)
                 )

               assert Base.encode16(:crypto.hash_final(hash), case: :lower) ==
                        reference["sha256"]
             end

             :ok
           end) == :ok

    assert Bodies.put(
             root,
             command_id,
             :response,
             reference("changed"),
             [
               "changed"
             ],
             @key
           ) == {:error, :body_conflict}

    assert {:ok, ^body, ^reference} = Bodies.fetch(root, command_id, :response)
  end

  test "bad hashes, lengths, directions and ids leave no published body", %{
    command_id: command_id,
    root: root
  } do
    for {reference, chunks} <- [
          {reference("expected"), ["wrong"]},
          {reference("same"), ["size"]},
          {reference("small"), ["too large"]}
        ] do
      assert {:error, _} =
               Bodies.put(root, command_id, :response, reference, chunks, @key)

      assert File.ls!(Path.join(root, command_id)) == []
    end

    assert {:error, _} =
             Bodies.put(root, "../escaped", :request, reference("x"), ["x"], @key)

    assert {:error, _} =
             Bodies.put(root, command_id, :other, reference("x"), ["x"], @key)

    assert {:error, _} = Bodies.fetch(root, command_id, :response)
  end

  test "only oversized JSON moves off the command envelope", %{command_id: command_id, root: root} do
    small = %{
      "method" => "POST",
      "path" => "/v1/sessions/s/turns",
      "body" => %{"prompt" => "short"}
    }

    assert {:ok, ^small} = Bodies.prepare_request(small, nil, command_id, @key)

    large = put_in(small, ["body", "prompt"], :binary.copy("p", 300 * 1_024))
    assert {:ok, request} = Bodies.prepare_request(large, root, command_id, @key)
    refute Map.has_key?(request, "body")
    assert request["method"] == "POST"
    assert {:ok, body, reference} = Bodies.fetch(root, command_id, :request)
    assert reference == request["body_ref"]
    assert {:ok, bytes} = Bodies.read(body, @key, 512 * 1_024)
    assert Jason.decode!(bytes) == large["body"]
    assert {:error, _} = Bodies.fetch(root, Ecto.UUID.generate(), :request, reference)
  end

  test "no plaintext is stored and tampering never reaches a consumer", %{
    command_id: command_id,
    root: root
  } do
    bytes = :binary.copy("private body", 100)
    ref = reference(bytes)
    assert Bodies.put(root, command_id, :response, ref, [bytes], @key) == :ok
    assert {:ok, body, ^ref} = Bodies.fetch(root, command_id, :response)
    path = Path.join([root, command_id, "response"])
    ciphertext = File.read!(Path.join(path, "data"))
    refute String.contains?(ciphertext, "private body")
    assert {:ok, ^bytes} = Bodies.read(body, @key, byte_size(bytes))
    assert Bodies.read(body, @key, byte_size(bytes) - 1) == {:error, :body_too_large}
    deny = fn _ -> flunk("unauthenticated plaintext reached the consumer") end
    assert {:error, _} = Bodies.with_stream(body, Ryker.Secret.new(:binary.copy(<<8>>, 32)), deny)

    for target <- [
          %{body | command_id: Ecto.UUID.generate()},
          %{body | direction: :request}
        ] do
      destination = Path.join([target.root, target.command_id, Atom.to_string(target.direction)])
      File.mkdir_p!(Path.dirname(destination))
      File.cp_r!(path, destination)
      assert {:error, _} = Bodies.with_stream(target, @key, deny)
    end

    <<first, rest::binary>> = ciphertext
    File.write!(Path.join(path, "data"), <<Bitwise.bxor(first, 1), rest::binary>>)
    assert {:error, _} = Bodies.with_stream(body, @key, deny)
  end

  test "canonical IDs and an open authenticated file survive spelling and pathname changes",
       %{command_id: command_id, root: root} do
    bytes = "immutable private bytes"
    ref = reference(bytes)

    assert Bodies.put(
             root,
             String.upcase(command_id),
             :response,
             ref,
             [bytes],
             @key
           ) == :ok

    assert {:ok, body, ^ref} = Bodies.fetch(root, command_id, :response)

    assert Bodies.with_stream(body, @key, fn stream ->
             path = Path.join([root, command_id, "response", "data"])
             File.rename!(path, path <> ".old")
             File.write!(path, :binary.copy("x", byte_size(bytes)))

             for _ <- 1..2,
                 do: assert(stream.() |> Enum.to_list() |> IO.iodata_to_binary() == bytes)

             :ok
           end) == :ok
  end

  defp reference(bytes),
    do: %{
      "byte_size" => byte_size(bytes),
      "sha256" => digest(bytes)
    }
end
