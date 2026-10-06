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

  # Learning reads a reply with the thread it answers, so a reply's "yes" can
  # be the answer to a question worth keeping. Threaded yes and no replies
  # were skipped as empty chat (2026-10-04 review).
  test "a bare reply in a thread is read with the question it answers" do
    reply = %Entry{
      content: %{"text" => "yes"},
      destination_thread_ref: "1788000000.000100",
      source_item_ref: "1788000060.000200"
    }

    refute EmptyChat.message?(reply)
    refute EmptyChat.message?(%{reply | content: %{"text" => "no thanks"}})

    # Thanks in a thread answers nothing; a harvested "Great thanks" reply
    # cost a learning call that saved nothing.
    assert EmptyChat.message?(%{reply | content: %{"text" => "Great thanks"}})

    # The thread's own opening message has no question above it.
    assert EmptyChat.message?(%{reply | source_item_ref: "1788000000.000100"})
  end

  defp entry(text), do: %Entry{content: %{"text" => text}}
end
