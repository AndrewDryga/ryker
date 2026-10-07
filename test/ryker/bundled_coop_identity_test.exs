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
    assert {"valid\n", 0} = run(context, "identity_state")
    assert {"", 0} = run(context, "recover_identity")
    assert File.exists?(marker)
    assert File.read!(identity) == original
  end

  test "expiry recovery removes only the expired identity and acknowledgement",
       %{identity: identity, marker: marker, root: root} = context do
    write_identity!(context, DateTime.add(DateTime.utc_now(), -3_600, :second))
    File.touch!(marker)
    assert {"expired\n", 0} = run(context, "identity_state")
    assert {_message, 0} = run(context, "recover_identity")
    refute File.exists?(identity)
    refute File.exists?(marker)
    assert File.read!(Path.join(root, "token")) == "keep this replacement token"
  end

  test "recovery rechecks a renewal that finished while the connector was stopping",
       %{identity: identity} = context do
    write_identity!(context, DateTime.add(DateTime.utc_now(), -3_600, :second))
    assert {"expired\n", 0} = run(context, "identity_state")
    renewed = write_identity!(context, DateTime.utc_now())
    assert {"", 0} = run(context, "recover_identity")
    assert File.read!(identity) == renewed
  end

  test "a missing identity clears a stale acknowledgement and keeps the token",
       %{marker: marker, root: root} = context do
    File.touch!(marker)
    assert {"absent\n", 0} = run(context, "identity_state")
    assert {"", 0} = run(context, "recover_identity")
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
          alter(document, "unknown", true)
        ] do
      File.write!(identity, replacement)
      assert {_message, 1} = run(context, "recover_identity")
      assert File.read!(identity) == replacement
    end
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

    assert {"", 0} = run(context, "set -e\nprepare_ryker_box\nprepare_ryker_box")
    assert File.read!(Path.join(root, "builds")) == tag <> "\n"

    assert File.read!(Path.join(root, "overlays")) ==
             String.duplicate("COOP_BASE_IMAGE=#{tag}\n", 2)

    File.write!(coop, File.read!(coop) <> "# a different worker binary\n")
    assert {"", 0} = run(context, "set -e\nprepare_ryker_box")

    assert [_first, second] =
             String.split(File.read!(Path.join(root, "builds")), "\n", trim: true)

    refute second == tag

    overlay_receipt = File.read!(Path.join(root, "overlays"))
    File.write!(coop, "#!/bin/sh\nexit 7\n")
    assert {"", 7} = run(context, "set -e\nprepare_ryker_box")
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
