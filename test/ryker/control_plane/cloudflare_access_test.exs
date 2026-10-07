defmodule Ryker.ControlPlane.CloudflareAccessTest do
  @moduledoc """
  Andrew, 2026-10-04: two client teams sign in to the console with
  Google through Cloudflare Access instead of joining his tailnet. Ryker names
  the person Access let in only after checking their token the way Cloudflare
  asks an origin to; anything else reaching the console at that address names
  nobody.
  """
  use ExUnit.Case, async: true
  import Plug.Conn, only: [put_req_header: 3]
  alias Ryker.ControlPlane.{BrowserGuard, CloudflareAccess, Viewer}

  setup do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    team = "team-#{System.unique_integer([:positive])}.cloudflareaccess.com"
    audience = String.duplicate("a", 64)
    reads = :counters.new(1, [])

    certs = fn ^team ->
      :counters.add(reads, 1, 1)
      {:ok, %{"keys" => [jwk(key, "current")]}}
    end

    %{
      config: %{team_domain: team, audience: audience, certs: certs},
      key: key,
      reads: reads,
      claims: %{
        "aud" => [audience],
        "email" => "dev@tenant.example",
        "exp" => now() + 600,
        "iat" => now(),
        "iss" => "https://" <> team,
        "nbf" => now(),
        "sub" => "7335d417-61da-459d-899c-0a01c76a2f94",
        "type" => "app"
      }
    }
  end

  test "a token Access signed for this application names its person", %{
    claims: claims,
    config: config,
    key: key
  } do
    token = token(key, "current", claims)

    assert {:ok, %{"email" => "dev@tenant.example"}} =
             CloudflareAccess.verify(token, config)

    conn = Plug.Test.conn(:get, "/") |> put_req_header("cf-access-jwt-assertion", token)

    # The sign-in counts until the token's expiry, with the minute of clock leeway `verify/2` allows.
    assert CloudflareAccess.viewer(conn, config) ==
             {:ok,
              %{
                login: "dev@tenant.example",
                name: "dev@tenant.example",
                via: :cloudflare,
                until: claims["exp"] + 60
              }}

    assert CloudflareAccess.viewer(Plug.Test.conn(:get, "/"), config) == :error
  end

  # The endpoint's guard, the router's guard, the person a request acts for
  # and each action's record of who took it each checked the token's
  # signature again: up to four RSA checks for one click (2026-10-04 review).
  # The guard checks it, and the request carries the person it named.
  test "the guard checks a request's token once for every step after it", %{
    claims: claims,
    config: config,
    key: key
  } do
    host = "console.tenant.example"

    conn =
      Plug.Test.conn(:get, "/")
      |> Map.merge(%{host: host, remote_ip: {127, 0, 0, 1}})
      |> put_req_header("cf-access-jwt-assertion", token(key, "current", claims))
      |> BrowserGuard.call(
        access: :loopback,
        public_host: host,
        cloudflare_access: config
      )

    refute conn.halted

    # The token is gone, and every later step still knows who took it.
    conn = Plug.Conn.delete_req_header(conn, "cf-access-jwt-assertion")
    options = %{public_host: host, cloudflare_access: config}
    assert %{login: "dev@tenant.example", via: :cloudflare} = Viewer.from_conn(conn, options)
    assert Viewer.actor_ref(conn, options) =~ "dev@tenant.example"
  end

  test "a token for another application or team, or outside its lifetime, names nobody",
       %{claims: claims, config: config, key: key} do
    for claims <- [
          %{claims | "aud" => [String.duplicate("b", 64)]},
          %{claims | "iss" => "https://other.cloudflareaccess.com"},
          %{claims | "exp" => now() - 120},
          %{claims | "nbf" => now() + 120},
          Map.delete(claims, "exp"),
          %{claims | "email" => ""}
        ] do
      token = token(key, "current", claims)
      conn = Plug.Test.conn(:get, "/") |> put_req_header("cf-access-jwt-assertion", token)
      assert CloudflareAccess.viewer(conn, config) == :error, inspect(claims)
    end
  end

  test "a token signed by another key, changed after signing, or unsigned names nobody",
       %{claims: claims, config: config, key: key} do
    other = :public_key.generate_key({:rsa, 2048, 65_537})

    assert CloudflareAccess.verify(token(other, "current", claims), config) ==
             :error

    [header, _claims, signature] =
      key |> token("current", claims) |> String.split(".")

    changed = encode(%{claims | "email" => "mallory@example.com"})
    assert CloudflareAccess.verify("#{header}.#{changed}.#{signature}", config) == :error

    unsigned = encode(%{"alg" => "none", "kid" => "current"})

    assert CloudflareAccess.verify("#{unsigned}.#{encode(claims)}.", config) ==
             :error

    for garbage <- [
          "",
          "a.b",
          "a.b.c.d",
          "#{header}.!!!.#{signature}",
          String.duplicate("x", 9_000)
        ] do
      assert CloudflareAccess.verify(garbage, config) == :error
    end
  end

  # Cloudflare publishes its next key before it signs with it, so the keys read once serve every
  # request; a token naming a key not seen yet reads them again, but never more than once a minute.
  test "the team's keys are read once and reused", %{
    claims: claims,
    config: config,
    key: key,
    reads: reads
  } do
    token = token(key, "current", claims)

    for _request <- 1..5,
        do: assert({:ok, _claims} = CloudflareAccess.verify(token, config))

    assert :counters.get(reads, 1) == 1

    unknown = token(key, "next", claims)
    assert CloudflareAccess.verify(unknown, config) == :error
    assert CloudflareAccess.verify(unknown, config) == :error
    assert :counters.get(reads, 1) == 1
  end

  # The keys were kept until a restart, so a key Cloudflare had retired still signed for the
  # console (2026-10-04 review). They are read again once an hour, and a key the team no longer
  # publishes is dropped.
  test "a key the team no longer publishes stops signing once the keys are read again", %{
    claims: claims,
    config: config,
    key: key
  } do
    rotated = :public_key.generate_key({:rsa, 2048, 65_537})
    published = :counters.new(1, [])
    team = config.team_domain

    certs = fn ^team ->
      if :counters.get(published, 1) == 0,
        do: {:ok, %{"keys" => [jwk(key, "current")]}},
        else: {:ok, %{"keys" => [jwk(rotated, "next")]}}
    end

    config = %{config | certs: certs}
    retired = token(key, "current", claims)
    assert {:ok, _claims} = CloudflareAccess.verify(retired, config)

    # Cloudflare publishes the next key and retires the old one; an hour on, the keys are read
    # again.
    :counters.add(published, 1, 1)
    cached = :persistent_term.get({CloudflareAccess, team})
    :persistent_term.put({CloudflareAccess, team}, %{cached | read_at: cached.read_at - 3_601})

    assert CloudflareAccess.verify(retired, config) == :error

    assert {:ok, _claims} =
             CloudflareAccess.verify(token(rotated, "next", claims), config)
  end

  defp token(key, kid, claims) do
    signing_input =
      encode(%{"alg" => "RS256", "kid" => kid, "typ" => "JWT"}) <> "." <> encode(claims)

    signature = :public_key.sign(signing_input, :sha256, key)
    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end

  defp jwk(key, kid) do
    {:RSAPrivateKey, _version, modulus, exponent, _d, _p, _q, _dp, _dq, _qi, _other} = key

    %{
      "alg" => "RS256",
      "e" => Base.url_encode64(:binary.encode_unsigned(exponent), padding: false),
      "kid" => kid,
      "kty" => "RSA",
      "n" => Base.url_encode64(:binary.encode_unsigned(modulus), padding: false),
      "use" => "sig"
    }
  end

  defp encode(value), do: value |> Jason.encode!() |> Base.url_encode64(padding: false)

  defp now, do: System.os_time(:second)
end
