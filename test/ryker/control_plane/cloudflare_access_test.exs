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

  alias Ryker.ControlPlane.CloudflareAccess

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

  test "a token Access signed for this application names its person", context do
    token = token(context.key, "current", context.claims)

    assert {:ok, %{"email" => "dev@tenant.example"}} =
             CloudflareAccess.verify(token, context.config)

    conn = Plug.Test.conn(:get, "/") |> put_req_header("cf-access-jwt-assertion", token)

    # The sign-in counts until the token's expiry, with the minute of clock leeway `verify/2` allows.
    assert CloudflareAccess.viewer(conn, context.config) ==
             {:ok,
              %{
                login: "dev@tenant.example",
                name: "dev@tenant.example",
                via: :cloudflare,
                until: context.claims["exp"] + 60
              }}

    assert CloudflareAccess.viewer(Plug.Test.conn(:get, "/"), context.config) == :error
  end

  test "a token for another application or team, or outside its lifetime, names nobody",
       context do
    for claims <- [
          %{context.claims | "aud" => [String.duplicate("b", 64)]},
          %{context.claims | "iss" => "https://other.cloudflareaccess.com"},
          %{context.claims | "exp" => now() - 120},
          %{context.claims | "nbf" => now() + 120},
          Map.delete(context.claims, "exp"),
          %{context.claims | "email" => ""}
        ] do
      token = token(context.key, "current", claims)
      conn = Plug.Test.conn(:get, "/") |> put_req_header("cf-access-jwt-assertion", token)
      assert CloudflareAccess.viewer(conn, context.config) == :error, inspect(claims)
    end
  end

  test "a token signed by another key, changed after signing, or unsigned names nobody",
       context do
    other = :public_key.generate_key({:rsa, 2048, 65_537})

    assert CloudflareAccess.verify(token(other, "current", context.claims), context.config) ==
             :error

    [header, _claims, signature] =
      context.key |> token("current", context.claims) |> String.split(".")

    changed = encode(%{context.claims | "email" => "mallory@example.com"})
    assert CloudflareAccess.verify("#{header}.#{changed}.#{signature}", context.config) == :error

    unsigned = encode(%{"alg" => "none", "kid" => "current"})

    assert CloudflareAccess.verify("#{unsigned}.#{encode(context.claims)}.", context.config) ==
             :error

    for garbage <- [
          "",
          "a.b",
          "a.b.c.d",
          "#{header}.!!!.#{signature}",
          String.duplicate("x", 9_000)
        ] do
      assert CloudflareAccess.verify(garbage, context.config) == :error
    end
  end

  # Cloudflare publishes its next key before it signs with it, so the keys read once serve every
  # request; a token naming a key not seen yet reads them again, but never more than once a minute.
  test "the team's keys are read once and reused", context do
    token = token(context.key, "current", context.claims)

    for _request <- 1..5,
        do: assert({:ok, _claims} = CloudflareAccess.verify(token, context.config))

    assert :counters.get(context.reads, 1) == 1

    unknown = token(context.key, "next", context.claims)
    assert CloudflareAccess.verify(unknown, context.config) == :error
    assert CloudflareAccess.verify(unknown, context.config) == :error
    assert :counters.get(context.reads, 1) == 1
  end

  # The keys were kept until a restart, so a key Cloudflare had retired still signed for the
  # console (2026-10-04 review). They are read again once an hour, and a key the team no longer
  # publishes is dropped.
  test "a key the team no longer publishes stops signing once the keys are read again", context do
    rotated = :public_key.generate_key({:rsa, 2048, 65_537})
    published = :counters.new(1, [])
    team = context.config.team_domain

    certs = fn ^team ->
      if :counters.get(published, 1) == 0,
        do: {:ok, %{"keys" => [jwk(context.key, "current")]}},
        else: {:ok, %{"keys" => [jwk(rotated, "next")]}}
    end

    config = %{context.config | certs: certs}
    retired = token(context.key, "current", context.claims)
    assert {:ok, _claims} = CloudflareAccess.verify(retired, config)

    # Cloudflare publishes the next key and retires the old one; an hour on, the keys are read
    # again.
    :counters.add(published, 1, 1)
    cached = :persistent_term.get({CloudflareAccess, team})
    :persistent_term.put({CloudflareAccess, team}, %{cached | read_at: cached.read_at - 3_601})

    assert CloudflareAccess.verify(retired, config) == :error

    assert {:ok, _claims} =
             CloudflareAccess.verify(token(rotated, "next", context.claims), config)
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
