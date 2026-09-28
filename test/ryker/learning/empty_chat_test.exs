defmodule Ryker.Learning.EmptyChatTest do
  use ExUnit.Case, async: true

  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.EmptyChat

  test "a greeting, thanks or bare acknowledgement is empty chat, however it is written" do
    for text <- [
          "hi",
          "Hi Ryker!",
          "<@U0RYKER> thanks 🙏",
          "thank you!!",
          ":thumbsup:",
          "👍",
          "ok",
          "Got it, thanks",
          "good morning",
          "yes"
        ] do
      assert EmptyChat.message?(entry(text)), text
    end
  end

  test "a message that says anything more, or carries a file, is learned from" do
    for text <- [
          "hi, the staging account moved to acme-stg2",
          "thanks, deploy it to staging next time",
          "ok use the eu region",
          "no, prod is acme-prd"
        ] do
      refute EmptyChat.message?(entry(text)), text
    end

    refute EmptyChat.message?(%Entry{
             content: %{"text" => "thanks", "files" => [%{"name" => "a.log"}]}
           })

    refute EmptyChat.message?(%Entry{content: %{"files" => [%{"transcript" => "hi"}]}})

    # An app's alert says everything outside its text: empty text is not "nothing".
    refute EmptyChat.message?(%Entry{
             content: %{
               "text" => "",
               "attachments" => [%{"title" => "HAProxy OOM"}],
               "blocks" => []
             }
           })

    refute EmptyChat.message?(%Entry{content: %{"text" => "ok", "bot_id" => "B123"}})
    refute EmptyChat.message?(%Entry{content: %{"text" => "ok", "subtype" => "bot_message"}})
    refute EmptyChat.all?([])
    refute EmptyChat.all?([entry("hi"), entry("the database is on pg18 now")])
    assert EmptyChat.all?([entry("hi"), entry("thanks")])
  end

  defp entry(text), do: %Entry{content: %{"text" => text}}
end
