defmodule Ryker.Improvement.Candidate do
  @moduledoc """
  One request people were unhappy with (`improvement_candidates`), kept so
  Ryker can say what went wrong and a person can turn it into an eval case
  (`Ryker.Improvement`).

  - `episode_id` or `input_id` names the request: its episode, or the message
    routing answered by itself. Like a routing example it names them without
    a foreign key; `request_ref` is the reference its Timeline opens by.
  - `reasons` are the kinds of negative feedback it got (`Ryker.Improvement.reasons/0`),
    `signal_count` how many negative signals, and `first_signal_at` and
    `last_signal_at` when the first and the latest arrived.
  - `status` is a person's decision: `open`, `accepted` as an eval case, or
    `dismissed`. An accepted case keeps the evidence it was accepted on
    (`case_evidence`), so it outlives the request's messages.
  - `analysis` is where Ryker's own diagnosis stands: `pending` until the
    request has come to rest and a quiet time has passed, `running` while a
    worker holds its lease, then `done` with `category`, `step`,
    `what_went_wrong`, `expected` and `confidence`, or `failed` with its
    `error_code` once it gave up.
  - `message_keys` and `conversation_refs` name the messages, topics and
    conversations its analysis and evidence quote, so forgetting any of them
    erases what it holds (`forgotten_at`).
  """
  use Ryker, :schema

  @categories [:host_bug, :prompt_bug, :model_mistake, :not_a_problem, :unclear]
  @steps [:routing, :work, :delivery]
  @confidences [:high, :medium, :low]

  schema "improvement_candidates" do
    field(:episode_id, :binary_id)
    field(:input_id, :binary_id)
    field(:request_ref, :string)
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:reasons, {:array, :string}, default: [])
    field(:signal_count, :integer, default: 1)
    field(:first_signal_at, :utc_datetime_usec)
    field(:last_signal_at, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: [:open, :accepted, :dismissed], default: :open)
    field(:decided_at, :utc_datetime_usec)
    field(:decided_by, :string)
    field(:case_evidence, Ryker.CanonicalJSON.Type)
    field(:message_keys, {:array, :string}, default: [])
    field(:conversation_refs, {:array, :string}, default: [])
    field(:forgotten_at, :utc_datetime_usec)
    field(:analysis, Ecto.Enum, values: [:pending, :running, :done, :failed], default: :pending)
    field(:start_count, :integer, default: 0)
    field(:start_limit, :integer, default: 3)
    field(:lease_ref, Ecto.UUID)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:error_code, :string)
    field(:category, Ecto.Enum, values: @categories)
    field(:step, Ecto.Enum, values: @steps)
    field(:what_went_wrong, :string)
    field(:expected, :string)
    field(:confidence, Ecto.Enum, values: @confidences)
    field(:analysis_target, :string)
    field(:analyzed_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}

  @doc "What went wrong, by whose fault, in the order the page lists them."
  @spec categories() :: [atom()]
  def categories, do: @categories

  @doc "Where it went wrong first."
  @spec steps() :: [atom()]
  def steps, do: @steps

  @doc "How sure the analysis is, surest first."
  @spec confidences() :: [atom()]
  def confidences, do: @confidences

  @doc "The request a candidate is about, as `Ryker.Feedback` names requests."
  @spec request(t()) :: Ryker.Feedback.request()
  def request(%__MODULE__{episode_id: id}) when is_binary(id), do: {:episode, id}
  def request(%__MODULE__{input_id: id}), do: {:input, id}
end
