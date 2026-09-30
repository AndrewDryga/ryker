defmodule Ryker.Transcription.LanguagesTest do
  use ExUnit.Case, async: true

  alias Ryker.Transcription.Languages

  # Andrew, 2026-09-28, of his 33-second voice message: it "did not properly
  # recognize i was speaking ukrainian, then switched to engligh, then to
  # spanish", and on 2026-09-30: "we should make voice inputs work reliably".
  # whisper's own pick for each part was Portuguese, English, Latin, Croatian,
  # Russian and Russian; the message was Ukrainian, English, Spanish and three
  # more Ukrainian parts. The fixture is whisper large-v3's probabilities for
  # the whole recording and for each part Ryker cuts it into.
  @fixture "testdata/transcription/voice-2026-09-28-language-probabilities.json"

  setup_all do
    {:ok, fixture: @fixture |> File.read!() |> Jason.decode!()}
  end

  test "each part of a mixed-language message is read in the language spoken there", %{
    fixture: fixture
  } do
    candidates = Languages.configured("uk, en,es")
    assert candidates == ["uk", "en", "es"]

    main = Languages.main(fixture["whole"], candidates)
    assert main == "uk"

    assert Enum.map(fixture["parts"], &Languages.part(&1, main, candidates)) ==
             fixture["expected"]

    # whisper's own pick for each part, the one it wrote each part in.
    refute Enum.map(fixture["parts"], &top/1) == fixture["expected"]
  end

  # Without the languages people speak, a short Ukrainian part that whisper
  # hears as Portuguese stays Portuguese: the preference for the message's
  # language is not enough on its own.
  test "without the team's languages, a misheard part keeps whisper's pick", %{
    fixture: fixture
  } do
    main = Languages.main(fixture["whole"], [])
    assert main == "uk"
    assert Languages.part(Enum.at(fixture["parts"], 0), main, []) == "pt"
  end

  test "no probabilities fall back to the message's language, then to whisper's choice" do
    assert Languages.part(%{}, "uk", ["uk", "en"]) == "uk"
    assert Languages.main(%{}, ["uk"]) == nil
    assert Languages.part(%{}, nil, []) == nil
    assert Languages.configured("ukrainian, EN, 42, e") == ["en"]
    assert Languages.configured(nil) == []
  end

  defp top(probabilities),
    do: probabilities |> Enum.max_by(fn {_language, value} -> value end) |> elem(0)
end
