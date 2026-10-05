defmodule Ryker.GatewayPkiTest do
  @moduledoc """
  The worker gateway's certificate, as the container issues and renews it
  before Ryker starts (`deploy/compose/gateway-pki.sh`), run here with the real
  openssl.

  Nothing renewed it, so TLS to the bundled worker would have broken about 825
  days after install, and half a CA was quietly replaced with a new one that
  signs nothing the enrolled workers trust, which left the worker crash-looping
  (2026-10-04 review).
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../deploy/compose/gateway-pki.sh", __DIR__)
  @worker_ip "172.30.42.10"

  setup do
    pki = Path.join(System.tmp_dir!(), "ryker-gateway-pki-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(pki) end)
    %{pki: pki}
  end

  test "a new installation gets a CA and a certificate for the names the worker dials",
       %{pki: pki} do
    assert {_out, 0} = run(pki)
    assert verified?(pki)
    assert {matched, 0} = openssl(~w(x509 -noout -checkip #{@worker_ip} -in) ++ [server(pki)])
    assert matched =~ "does match certificate"
  end

  test "a certificate that ends within 30 days is renewed", %{pki: pki} do
    assert {_out, 0} = run(pki)
    issue!(pki, ca_dir: pki, days: 10)
    refute lasts_30_days?(pki)

    assert {_out, 0} = run(pki)
    assert lasts_30_days?(pki)
    assert verified?(pki)
  end

  test "a certificate another CA signed is reissued by this one", %{pki: pki} do
    assert {_out, 0} = run(pki)
    other = pki <> "-other-ca"
    on_exit(fn -> File.rm_rf!(other) end)
    assert {_out, 0} = run(other)
    issue!(pki, ca_dir: other, days: 400)
    refute verified?(pki)

    assert {_out, 0} = run(pki)
    assert verified?(pki)
  end

  test "half a CA refuses to start and changes nothing", %{pki: pki} do
    assert {_out, 0} = run(pki)
    File.rm!(Path.join(pki, "ca-key.pem"))
    ca = File.read!(Path.join(pki, "ca.pem"))

    assert {refused, 1} = run(pki)
    assert refused =~ "Restore both from a backup"
    assert File.read!(Path.join(pki, "ca.pem")) == ca
    refute File.exists?(Path.join(pki, "ca-key.pem"))
  end

  defp run(pki), do: System.cmd("sh", [@script, pki, @worker_ip], stderr_to_stdout: true)

  defp openssl(arguments), do: System.cmd("openssl", arguments, stderr_to_stdout: true)

  defp server(pki), do: Path.join(pki, "server.pem")

  defp verified?(pki),
    do: match?({_out, 0}, openssl(["verify", "-CAfile", Path.join(pki, "ca.pem"), server(pki)]))

  defp lasts_30_days?(pki),
    do: match?({_out, 0}, openssl(["x509", "-noout", "-checkend", "2592000", "-in", server(pki)]))

  # A server certificate for the right names, signed by the CA in `ca_dir`.
  defp issue!(pki, ca_dir: ca_dir, days: days) do
    csr = Path.join(pki, "test.csr")
    extensions = Path.join(pki, "test.ext")
    File.write!(extensions, "subjectAltName=DNS:ryker,IP:127.0.0.1,IP:#{@worker_ip}\n")

    {_out, 0} =
      openssl(
        ~w(req -new -subj /CN=ryker -key) ++ [Path.join(pki, "server-key.pem"), "-out", csr]
      )

    {_out, 0} =
      openssl(
        ["x509", "-req", "-in", csr, "-CA", Path.join(ca_dir, "ca.pem")] ++
          ["-CAkey", Path.join(ca_dir, "ca-key.pem"), "-CAcreateserial"] ++
          ["-out", server(pki), "-days", Integer.to_string(days), "-extfile", extensions]
      )

    File.rm!(csr)
    File.rm!(extensions)
  end
end
