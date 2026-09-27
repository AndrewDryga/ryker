defmodule Ryker.Admission.Sentiment do
  @moduledoc """
  How the person who sent a message feels about Ryker's previous answer, as
  routing read it from that message: satisfied, neutral, frustrated or
  angry, with a short reason.

  Andrew, 2026-09-27: "add a task to sentiment-analysis during router (so
  routing model also evaluates sentiment that user has while working with
  it) and use that sentiment as indirect feedback channel". Routing reports
  it only when the message is a person's and follows one of Ryker's answers
  in the same place (`Ryker.Admission.Context`, `previous_answer`), and it
  is kept as feedback on that answer's request (`Ryker.Feedback`).

  The model's answer is an input, not a dependency: sentiment is optional,
  and a result without one, or with one Ryker cannot read, is routed exactly
  the same. The response format shows the shape it wants but refuses no
  other value, so Coop never asks the model to correct it, and the host
  never does either: it keeps a feeling it knows and a reason that is plain
  text short enough, and leaves out the rest without a word.
  """

  @feelings %{
    "satisfied" => :satisfied,
    "neutral" => :neutral,
    "frustrated" => :frustrated,
    "angry" => :angry
  }
  @maximum_reason 280
  @nonblank_pattern "^[^\\x00]*[^\\s\\x00][^\\x00]*$"

  @type t :: %{
          feeling: :satisfied | :neutral | :frustrated | :angry,
          reason: String.t() | nil
        }

  @doc """
  The sentiment in a routing result's `sentiment` value, or nil. A feeling
  that is not one of the four leaves the whole sentiment out; a reason that
  is missing, blank, not text or longer than 280 characters leaves out only
  the reason. Other keys are ignored.
  """
  @spec parse(term()) :: t() | nil
  def parse(%{"feeling" => feeling} = value) when is_binary(feeling) do
    case Map.fetch(@feelings, feeling) do
      {:ok, feeling} -> %{feeling: feeling, reason: reason(Map.get(value, "reason"))}
      :error -> nil
    end
  end

  def parse(_value), do: nil

  @doc "A sentiment the host already holds, checked again the same way, or nil."
  @spec prepare(term()) :: t() | nil
  def prepare(%{feeling: feeling, reason: reason}) when is_atom(feeling) do
    if feeling in Map.values(@feelings),
      do: %{feeling: feeling, reason: reason(reason)},
      else: nil
  end

  def prepare(_sentiment), do: nil

  @doc """
  The response format's `sentiment` property: the shape routing is asked
  for, and, as its last branch, anything else, which the host ignores. Coop
  validates the whole result against the format, so a stricter property
  would make a mistyped feeling a reason to correct the routing decision.
  """
  @spec json_schema() :: map()
  def json_schema do
    %{
      "anyOf" => [
        %{
          "additionalProperties" => false,
          "properties" => %{
            "feeling" => %{"enum" => ~w(satisfied neutral frustrated angry)},
            "reason" => %{
              "maxLength" => @maximum_reason,
              "minLength" => 1,
              "pattern" => @nonblank_pattern,
              "type" => "string"
            }
          },
          "required" => ["feeling", "reason"],
          "type" => "object"
        },
        %{"type" => "null"},
        %{"description" => "Any other value is ignored; it is never refused or corrected."}
      ]
    }
  end

  defp reason(value) when is_binary(value) do
    if String.valid?(value) and not String.contains?(value, <<0>>) and String.trim(value) != "" and
         String.length(value) <= @maximum_reason,
       do: value,
       else: nil
  end

  defp reason(_value), do: nil
end
