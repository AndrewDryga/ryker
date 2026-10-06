defmodule Ryker.LocalRouting.EndpointTest do
  use ExUnit.Case, async: true
  alias Ryker.LocalRouting.Endpoint

  # Every routing prompt holds a person's message and the conversation around
  # it. Plain http is fine to the Mac running Ryker (host.docker.internal from
  # inside Compose) or across a private network; across the internet it would
  # hand every conversation to whoever is on the path, so it needs https.
  test "plain http reaches only this machine or a private network, anywhere else needs https" do
    for url <- [
          "http://host.docker.internal:11434/v1",
          "http://localhost:11434/v1",
          "http://127.0.0.1:11434/v1",
          "http://[::1]:11434/v1",
          "http://192.168.1.20:11434/v1",
          "http://10.0.0.5/v1",
          "http://172.16.3.4:8080/v1",
          "http://100.101.102.103:11434/v1",
          "http://gpu-box.local:11434/v1",
          "http://gpu.example-tailnet.ts.net/v1",
          "https://llm.example.com/v1"
        ] do
      assert Endpoint.check(url) == :ok, url
    end

    for url <- [
          "http://llm.example.com/v1",
          "http://8.8.8.8/v1",
          "http://172.32.0.1/v1",
          "http://192.169.0.1/v1",
          "http://localhost.example.com/v1"
        ] do
      assert Endpoint.check(url) == {:error, :insecure}, url
    end
  end

  test "an endpoint is one plain address, never credentials, a query or anything else" do
    for url <- [
          "",
          "host.docker.internal:11434/v1",
          "ftp://localhost/v1",
          "http:///v1",
          "http://user:secret@localhost:11434/v1",
          "http://localhost:11434/v1?key=value",
          "http://localhost:11434/v1#part",
          " http://localhost:11434/v1",
          "http://local host:11434/v1",
          "http://localhost:11434/" <> String.duplicate("v", 2_100),
          nil,
          42
        ] do
      assert Endpoint.check(url) == {:error, :format}, inspect(url)
    end
  end

  test "requests go to the chat completions address under the saved endpoint" do
    assert Endpoint.completions("http://host.docker.internal:11434/v1") ==
             "http://host.docker.internal:11434/v1/chat/completions"

    assert Endpoint.completions("http://host.docker.internal:11434/v1/") ==
             "http://host.docker.internal:11434/v1/chat/completions"
  end
end
