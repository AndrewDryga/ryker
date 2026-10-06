defmodule Ryker.EmbeddingsTest do
  # Routing's search by meaning reads vectors from any server that answers the
  # OpenAI embeddings API (`Ryker.Embeddings`). What it does with an answer is
  # held here with a stand-in server; no test calls a model.
  use ExUnit.Case, async: true
  alias Ryker.Embeddings

  test "vectors come back in the order asked, each of length one" do
    request = fn url, body, _timeout ->
      assert url == "http://embed.test:8180/v1/embeddings"
      assert %{"input" => ["first", "second"], "model" => "bge-m3"} = Jason.decode!(body)

      {:ok,
       %{
         "data" => [
           %{"index" => 1, "embedding" => [0.0, 2.0]},
           %{"index" => 0, "embedding" => [3.0, 4.0]}
         ]
       }}
    end

    assert Embeddings.embed(["first", "second"],
             url: "http://embed.test:8180",
             model: "bge-m3",
             request: request
           ) == {:ok, [[0.6, 0.8], [0.0, 1.0]]}
  end

  test "an answer that is not one vector per text of one size is not used" do
    for answer <- [
          %{"data" => [%{"index" => 0, "embedding" => [1.0, 0.0]}]},
          %{
            "data" => [
              %{"index" => 0, "embedding" => [1.0, 0.0]},
              %{"index" => 1, "embedding" => [1.0, 0.0, 0.0]}
            ]
          },
          %{
            "data" => [%{"index" => 0, "embedding" => ["a"]}, %{"index" => 1, "embedding" => [1]}]
          },
          %{"error" => "model not loaded"}
        ] do
      request = fn _url, _body, _timeout -> {:ok, answer} end

      assert Embeddings.embed(["one", "two"], url: "http://embed.test", request: request) ==
               {:error, :unreadable_answer}
    end
  end

  test "without a server there is nothing to ask, and a server's failure says why" do
    assert Embeddings.embed(["one"], url: nil) == {:error, :not_configured}

    request = fn _url, _body, _timeout -> {:error, :unreachable} end

    assert Embeddings.embed(["one"], url: "http://embed.test", request: request) ==
             {:error, :unreachable}

    assert Embeddings.embed([], url: "http://embed.test") == {:error, :invalid_text}
    assert Embeddings.embed([""], url: "http://embed.test") == {:error, :invalid_text}
  end
end
