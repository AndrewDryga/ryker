defmodule Ryker.Transcription.Languages do
  @moduledoc """
  Which language each part of a recording is read in.

  Andrew's 33-second voice message of 2026-09-28 went from Ukrainian to
  English to Spanish and back. whisper's language detection is sure of a whole
  recording (large-v3: Ukrainian 0.87) and unsure of a few seconds of it: its
  Ukrainian parts read as Portuguese (0.85), Croatian (0.88) and Russian
  (0.94), and each was then written in that language. Two rules fix that:

    * only the languages people speak here are candidates
      (`RYKER_VOICE_LANGUAGES`, for example `uk,en,es`); with none named, any
      language is;
    * the language of the whole recording is preferred: a part is read in
      another candidate only where that one is five times likelier there,
      which a clear English or Spanish sentence is and a short Ukrainian one
      misheard as Russian is not.

  Probabilities are whisper's own, keyed by language code, as whisper.cpp's
  server reports them.
  """

  @preference 5.0

  @doc "The candidate languages named in `RYKER_VOICE_LANGUAGES`, in order."
  @spec configured(String.t() | nil) :: [String.t()]
  def configured(value \\ System.get_env("RYKER_VOICE_LANGUAGES"))

  def configured(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&Regex.match?(~r/\A[a-z]{2,3}\z/, &1))
    |> Enum.uniq()
  end

  def configured(_value), do: []

  @doc "The language of the whole recording among the candidates, or nil when whisper gave none."
  @spec main(map(), [String.t()]) :: String.t() | nil
  def main(probabilities, candidates),
    do: likeliest(probabilities, candidates, fn _language -> 1.0 end)

  @doc "The language one part is read in, preferring the whole recording's."
  @spec part(map(), String.t() | nil, [String.t()]) :: String.t() | nil
  def part(probabilities, main, candidates) do
    case likeliest(probabilities, candidates, &if(&1 == main, do: @preference, else: 1.0)) do
      nil -> main
      language -> language
    end
  end

  defp likeliest(probabilities, candidates, weight) when is_map(probabilities) do
    candidates = if candidates == [], do: Map.keys(probabilities), else: candidates

    candidates
    |> Enum.map(&{&1, probability(probabilities, &1) * weight.(&1)})
    |> Enum.filter(fn {_language, score} -> score > 0 end)
    |> case do
      [] -> nil
      scored -> scored |> Enum.max_by(fn {_language, score} -> score end) |> elem(0)
    end
  end

  defp likeliest(_probabilities, _candidates, _weight), do: nil

  defp probability(probabilities, language) do
    case Map.get(probabilities, language) do
      value when is_number(value) and value >= 0 -> value * 1.0
      _missing -> 0.0
    end
  end
end
