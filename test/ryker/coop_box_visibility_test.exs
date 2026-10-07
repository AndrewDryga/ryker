defmodule Ryker.CoopBoxVisibilityTest do
  @moduledoc """
  Agents work on this repository inside Coop boxes, and a box shows an empty
  decoy in place of every path whose name is on Coop's built-in secret list.
  On 2026-10-01 that hid `lib/ryker/credentials/`: `Ryker.Credentials` could not
  compile in any box, and a box agent spent its evening unable to run a single
  test. A tracked path with such a name breaks every box, so it fails here first.
  """
  use ExUnit.Case, async: true

  # Coop's built-in names, matched case-insensitively against each path segment
  # (SecretGlobs, AllowGlobs and the template rule in Coop's
  # internal/shadowpath/shadowpath.go). A .coopignore can hide more, never less.
  @secret_names ~w(
    .env .env.* .envrc *.secret *.secrets *.tfvars *.tfvars.json *.tfstate *.tfstate.*
    *.pem *.key *.p12 *.pfx *.jks *.keystore *.p8 *.ppk *.kdbx *.ovpn *.pkcs12
    id_rsa* id_ed25519* id_ecdsa* id_dsa*
    .netrc _netrc .npmrc .yarnrc .yarnrc.yml .pypirc .git-credentials .htpasswd
    .dockercfg .pgpass .my.cnf .s3cfg .boto .vault-token vault-token
    secrets .secrets credentials .aws .kube .ssh .gnupg .docker
    credentials.json service_account.json service-account.json *-sa.json client_secret*.json
    firebase-adminsdk*.json gha-creds-*.json auth.json secret.json secrets.json *.secret.json
    kubeconfig kubeconfig.yaml kubeconfig.yml database.yml credentials.y*ml secrets.y*ml
  )
  @allowed_names ~w(cacerts.pem cacert.pem ca-bundle.pem ca-bundle.crt ca-certificates.crt ca-cert.pem)
  @template_names ~w(*.example *.sample *.template)
  @key_names ~w(
    *.pem *.key *.p12 *.pfx *.jks *.keystore *.p8 *.ppk *.kdbx *.pkcs12
    id_rsa* id_ed25519* id_ecdsa* id_dsa*
  )

  test "every repository file is visible inside a Coop box" do
    root = Path.expand("../..", __DIR__)

    {output, 0} =
      System.cmd("git", ["ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cd: root
      )

    hidden =
      output
      |> String.split(<<0>>, trim: true)
      |> Enum.filter(fn path -> path |> Path.split() |> Enum.any?(&hidden_in_box?/1) end)

    assert hidden == [], """
    A Coop box replaces these paths with empty decoys, so no agent there can build or
    test them. Rename them:

    #{Enum.join(hidden, "\n")}
    """
  end

  defp hidden_in_box?(segment) do
    name = String.downcase(segment)

    allowed =
      matches?(name, @allowed_names) or
        (matches?(name, @template_names) and not matches?(name, @key_names))

    matches?(name, @secret_names) and not allowed
  end

  defp matches?(name, globs) do
    Enum.any?(globs, fn glob ->
      pattern = glob |> Regex.escape() |> String.replace("\\*", ".*")
      Regex.match?(~r/\A#{pattern}\z/, name)
    end)
  end
end
