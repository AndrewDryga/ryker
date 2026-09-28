defmodule Ryker.Learning.EmptyChat do
  @moduledoc """
  Messages learning can safely leave alone: a greeting, thanks or a bare
  acknowledgement, with nothing attached.

  Learning reads only what people said, never Ryker's replies, so a batch of
  such messages has nothing a model could learn: "ok" or "yes" without the
  question it answers says nothing. Every "hi" used to start a learning model
  call that saved nothing (2026-09-28). The test is deliberately narrow: a
  message that says anything more, such as "hi, the staging account moved",
  is learned from as before, and so is any message with a file.
  """

  alias Ryker.Ingress.Inbox.Entry

  # Every word of an empty-chat message is one of these; one other word, such
  # as "deployed" in "got it, deployed", and the message is learned from.
  @filler MapSet.new(~w(
            hi hello hey hiya yo sup howdy there good morning afternoon evening
            thanks thank thankyou thx ty cheers you a lot many much
            ok okay okey k kk cool great nice awesome perfect lol
            yes yep yeah yup no nope sure np got it sounds all problem
          ))

  @doc "Whether every message is empty chat; an empty list is not."
  @spec all?([Entry.t()]) :: boolean()
  def all?([_ | _] = entries), do: Enum.all?(entries, &message?/1)
  def all?(_entries), do: false

  @doc "Whether one message is a greeting, thanks or bare acknowledgement with nothing attached."
  @spec message?(Entry.t()) :: boolean()
  def message?(%Entry{content: %{"text" => text} = content}) when is_binary(text) do
    String.trim(text) != "" and plain?(content) and
      Enum.all?(words(text), &MapSet.member?(@filler, &1))
  end

  def message?(_entry), do: false

  # A person's own words and nothing else. An app's alert often has no text of
  # its own and says everything in attachments or blocks; a file, an
  # attachment, a bot or any Slack subtype means there is more to read.
  defp plain?(content) do
    Enum.all?(~w(files attachments), &(content |> Map.get(&1) |> List.wrap() == [])) and
      Map.get(content, "bot_id") in [nil, ""] and Map.get(content, "subtype") in [nil, ""]
  end

  # Slack mentions and links, :emoji: codes, and Ryker's own name go; what is
  # left is lower-case words. Only emoji or mentions leaves none.
  defp words(text) do
    text
    |> String.replace(~r/<[@#!][^>]*>/u, " ")
    |> String.replace(~r/:[a-z0-9_+\-]+:/u, " ")
    |> String.downcase()
    |> String.replace(~r/[^\p{L}\p{N}\s]/u, " ")
    |> String.split()
    |> Enum.reject(&(&1 == "ryker"))
  end
end
