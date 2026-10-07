defmodule Ryker.LocalRouting.Comparison do
  @moduledoc """
  One routing decision asked again of the local routing model.

  `pending` until the local model answers or the lane gives up;
  `next_attempt_at` is when it may be asked next, and while an attempt runs it
  fences that attempt, so a lane that stopped mid-call is asked again once the
  call's firm timeout has passed. `compared` once it answered: `valid` says
  whether routing's own checks accepted the answer, `invalid_reason` why not,
  and `agrees` whether it decided what the provider decided, with the fields
  it did not (`Ryker.LocalRouting.Verdict`). `failed` when no usable answer
  came back, with `last_error` saying why.

  Beside the local model's answer, its time and token counts, it keeps what
  the provider's call for the same message cost and how long it took, so a
  cascade's savings can be read off the comparisons alone.

  `source_identity`, `message_keys` and `conversation_refs` name what its
  prompt quotes, as a routing example names them
  (`Ryker.RoutingExamples.quoted_keys/1`), so a person forgetting any of it
  erases the comparison.
  """
  use Ryker, :schema

  @type t :: %__MODULE__{}

  schema "local_routing_comparisons" do
    belongs_to(:input, Ryker.Ingress.Inbox.Entry)
    field(:generation, :integer)
    field(:execution_mode, Ecto.Enum, values: [:live, :shadow])
    field(:status, Ecto.Enum, values: [:pending, :compared, :failed], default: :pending)
    field(:attempt_count, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:last_error, :string)
    field(:local_model, :string)
    field(:valid, :boolean)
    field(:invalid_reason, :string)
    field(:agrees, :boolean)
    field(:differing_fields, {:array, :string}, default: [])
    field(:local_answer, :string)
    field(:local_ms, :integer)
    field(:local_input_tokens, :integer)
    field(:local_output_tokens, :integer)
    field(:provider_cost_usd, :decimal)
    field(:provider_cost_estimated, :boolean)
    field(:provider_ms, :integer)
    field(:compared_at, :utc_datetime_usec)
    field(:source_identity, :string)
    field(:message_keys, {:array, :string}, default: [])
    field(:conversation_refs, {:array, :string}, default: [])
    timestamps()
  end
end
