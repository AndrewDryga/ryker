defmodule Ryker.Skills.Document do
  @moduledoc "Reads the name and description from a bounded Markdown skill and fingerprints its original bytes."
  alias Ryker.Crypto

  @name ~r/\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
  @header ~r/\A---\r?\n(.+?)\r?\n---[ \t]*\r?\n(.*)\z/s

  @spec parse(term()) :: {:ok, map()} | {:error, :invalid_skill}
  def parse(document) when is_binary(document) and byte_size(document) in 1..32_768 do
    with true <- String.valid?(document) and not String.contains?(document, <<0>>),
         [header, body] <- Regex.run(@header, document, capture: :all_but_first),
         true <- byte_size(header) <= 4096 and String.trim(body) != "",
         # A skill's metadata needs only plain YAML. Reject anchors, aliases and
         # explicit type tags before handing third-party frontmatter to the parser.
         false <- Regex.match?(~r/(?:^|[\s\[{,:])(?:[&*!]\S)/, header),
         {:ok, %{"name" => name, "description" => description}} <-
           YamlElixir.read_from_string(header),
         true <- is_binary(name) and byte_size(name) <= 64 and Regex.match?(@name, name),
         true <-
           is_binary(description) and String.length(description) in 1..1024 and
             String.trim(description) != "" do
      {:ok,
       %{
         "name" => name,
         "description" => description,
         "document" => document,
         "sha256" => Crypto.sha256_hex(document)
       }}
    else
      _invalid -> {:error, :invalid_skill}
    end
  end

  def parse(_document), do: {:error, :invalid_skill}
end
