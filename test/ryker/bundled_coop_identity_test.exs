defmodule Ryker.BundledCoopIdentityTest do
  use ExUnit.Case, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.CoopFleet.CertificateAuthority

  @controller "https://172.30.42.10:4322"

  setup do
    root = Path.join(System.tmp_dir!(), "ryker identity #{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    authority =
      :public_key.pkix_test_root_cert(~c"Ryker Test Worker CA",
        digest: :sha256,
        key: {:rsa, 2_048, 65_537}
      )

    key = :public_key.generate_key({:rsa, 2_048, 65_537})
    public = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    ca = :public_key.pem_encode([{:Certificate, authority.cert, :not_encrypted}])
    File.write!(Path.join(root, "ca.pem"), ca)
    File.write!(Path.join(root, "token"), "keep this replacement token")

    %{
      root: root,
      ca: ca,
      ca_key: pem(:RSAPrivateKey, authority.key),
      private: pem(:RSAPrivateKey, key),
      public: pem(:SubjectPublicKeyInfo, public),
      identity: Path.join(root, "identity.json"),
      marker: Path.join(root, "enrolled")
    }
  end

  test "a valid identity is retained and its durable installation is acknowledged",
       %{identity: identity, marker: marker} = context do
    original = write_identity!(context, DateTime.utc_now())
    assert run(context, "identity_state") == {"valid\n", 0}
    assert run(context, "recover_identity") == {"", 0}
    assert File.exists?(marker)
    assert File.read!(identity) == original
  end

  test "expiry recovery removes only the expired identity and acknowledgement",
       %{identity: identity, marker: marker, root: root} = context do
    write_identity!(context, DateTime.add(DateTime.utc_now(), -3_600, :second))
    File.touch!(marker)
    assert run(context, "identity_state") == {"expired\n", 0}
    assert {_message, 0} = run(context, "recover_identity")
    refute File.exists?(identity)
    refute File.exists?(marker)
    assert File.read!(Path.join(root, "token")) == "keep this replacement token"
  end

  test "recovery rechecks a renewal that finished while the connector was stopping",
       %{identity: identity} = context do
    write_identity!(context, DateTime.add(DateTime.utc_now(), -3_600, :second))
    assert run(context, "identity_state") == {"expired\n", 0}
    renewed = write_identity!(context, DateTime.utc_now())
    assert run(context, "recover_identity") == {"", 0}
    assert File.read!(identity) == renewed
  end

  test "a missing identity clears a stale acknowledgement and keeps the token",
       %{marker: marker, root: root} = context do
    File.touch!(marker)
    assert run(context, "identity_state") == {"absent\n", 0}
    assert run(context, "recover_identity") == {"", 0}
    refute File.exists?(marker)
    assert File.exists?(Path.join(root, "token"))
  end

  test "malformed or mismatched identity data is never treated as expiry",
       %{identity: identity} = context do
    document = write_identity!(context, DateTime.add(DateTime.utc_now(), -3_600, :second))

    for replacement <- [
          "{bad json",
          String.duplicate("x", 65_537),
          alter(document, "controller_url", "https://other.example"),
          alter(document, "worker_id", "another-worker"),
          alter(document, "workspace_ref", "another-workspace"),
          alter(document, "certificate_pem", "not a certificate"),
          alter(document, "private_key_pem", "not a key"),
          document |> Jason.decode!() |> Map.delete("workspace_ref") |> Jason.encode!()
        ] do
      File.write!(identity, replacement)
      assert {_message, 1} = run(context, "recover_identity")
      assert File.read!(identity) == replacement
    end
  end

  # 2026-10-04 review: the check wanted exactly the six keys this Coop writes, so a Coop pin
  # that adds one would have left the worker refusing its own identity and unable to start
  # until someone deleted it by hand. What it checks is still all there.
  test "an identity a newer Coop wrote with a field of its own stays valid",
       %{identity: identity} = context do
    document = write_identity!(context, DateTime.utc_now())
    newer = alter(document, "renewed_at", "2026-10-07T00:00:00Z")
    File.write!(identity, newer)

    assert run(context, "identity_state") == {"valid\n", 0}
    assert run(context, "recover_identity") == {"", 0}
    assert File.read!(identity) == newer
  end

  test "symlinks and nonprivate files are refused without touching their content",
       %{identity: identity, root: root} = context do
    document = write_identity!(context, DateTime.add(DateTime.utc_now(), -3_600, :second))
    File.chmod!(identity, 0o644)
    assert {_message, 1} = run(context, "recover_identity")
    target = Path.join(root, "target")
    File.rename!(identity, target)
    File.ln_s!(target, identity)
    assert {_message, 1} = run(context, "recover_identity")
    assert File.read!(target) == document
  end

  test "the trusted box uses this worker binary's base, reuses it, and stops on a failed build",
       %{root: root} = context do
    # A bare coop-box image from an older worker masked the missing-base path:
    # Coop now builds definition-tagged bases, so a clean worker could not boot.
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    coop = Path.join(bin, "coop")
    docker = Path.join(bin, "docker")

    File.write!(coop, """
    #!/bin/sh
    [ "$*" = 'build --egress open' ] || exit 91
    printf '%s\\n' "$COOP_BASE_IMAGE" >> "$state/builds"
    touch "$state/$COOP_BASE_IMAGE"
    """)

    File.write!(docker, """
    #!/bin/sh
    case "$1 $2" in
      'image ls')
        for image in "$state"/ryker-coop-base:*; do
          [ -e "$image" ] && basename "$image"
        done
        exit 0 ;;
      'image rm')
        printf '%s\\n' "$3" >> "$state/removed"
        rm -f "$state/$3"
        exit 0 ;;
      'image prune')
        printf '%s\\n' "$*" >> "$state/pruned"
        exit 0 ;;
    esac
    case "$1 $2 $3" in
      'image inspect ryker-coop-base:'*)
        [ -f "$state/$3" ] || exit 1
        printf '%s\\n' "$3" ;;
      'image inspect ryker-coop-box') : ;;
      'build --build-arg COOP_BASE_IMAGE=ryker-coop-base:'*)
        printf '%s\\n' "$3" >> "$state/overlays" ;;
      *) exit 92 ;;
    esac
    """)

    File.chmod!(coop, 0o700)
    File.chmod!(docker, 0o700)
    File.write!(Path.join(root, "Box.Dockerfile"), "FROM ${COOP_BASE_IMAGE}\n")

    tag =
      "ryker-coop-base:" <> digest(File.read!(coop))

    assert run(context, "set -e\nprepare_ryker_box\nprepare_ryker_box") == {"", 0}
    assert File.read!(Path.join(root, "builds")) == tag <> "\n"

    assert File.read!(Path.join(root, "overlays")) ==
             String.duplicate("COOP_BASE_IMAGE=#{tag}\n", 2)

    File.write!(coop, File.read!(coop) <> "# a different worker binary\n")
    assert run(context, "set -e\nprepare_ryker_box") == {"", 0}

    assert [_first, second] =
             String.split(File.read!(Path.join(root, "builds")), "\n", trim: true)

    refute second == tag

    # Each Coop version left its base behind in the worker's Docker, and each rebuild the box it
    # replaced (2026-10-04 review): the base an older binary built goes once this one has its
    # own, and images nothing is tagged as are pruned.
    assert File.read!(Path.join(root, "removed")) == tag <> "\n"
    refute File.exists?(Path.join(root, tag))
    assert File.exists?(Path.join(root, second))
    assert File.read!(Path.join(root, "pruned")) =~ "image prune --force"

    overlay_receipt = File.read!(Path.join(root, "overlays"))
    File.write!(coop, "#!/bin/sh\nexit 7\n")
    assert run(context, "set -e\nprepare_ryker_box") == {"", 7}
    assert File.read!(Path.join(root, "overlays")) == overlay_receipt
  end

  defp write_identity!(context, now) do
    {:ok, issued} =
      CertificateAuthority.issue(
        context.public,
        "ryker-compose",
        context.ca,
        context.ca_key,
        now,
        600
      )

    document =
      Jason.encode!(%{
        "controller_url" => @controller,
        "worker_id" => "ryker-compose",
        "workspace_ref" => "ryker-compose",
        "certificate_pem" => issued.certificate_pem,
        "ca_certificate_pem" => context.ca,
        "private_key_pem" => context.private
      })

    File.write!(context.identity, document)
    File.chmod!(context.identity, 0o600)
    document
  end

  defp run(context, command) do
    source = File.read!("deploy/compose/coop/entrypoint.sh")

    functions =
      for name <- ~w(identity_state recover_identity prepare_ryker_box) do
        [function] = Regex.run(~r/^#{name}\(\) \{.*?^\}/ms, source)
        function
      end

    System.cmd("sh", ["-c", Enum.join(functions, "\n") <> "\n" <> command],
      stderr_to_stdout: true,
      env: [
        {"PATH", Path.join(context.root, "bin") <> ":" <> System.fetch_env!("PATH")},
        {"state", context.root},
        {"trusted_box", "ryker-coop-box"},
        {"trusted_box_dockerfile", Path.join(context.root, "Box.Dockerfile")},
        {"identity", context.identity},
        {"marker", context.marker},
        {"ca", Path.join(context.root, "ca.pem")},
        {"controller", @controller},
        {"worker_id", "ryker-compose"},
        {"workspace_ref", "ryker-compose"}
      ]
    )
  end

  defp alter(document, key, value),
    do: document |> Jason.decode!() |> Map.put(key, value) |> Jason.encode!()

  defp pem(type, key),
    do: type |> :public_key.pem_entry_encode(key) |> then(&:public_key.pem_encode([&1]))
end
