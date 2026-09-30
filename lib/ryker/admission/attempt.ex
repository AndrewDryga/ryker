defmodule Ryker.Admission.Attempt do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "admission_attempts" do
    belongs_to(:input, Ryker.Ingress.Inbox.Entry)
    field(:generation, :integer)
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:submission, Ryker.CanonicalJSON.Type)
    field(:submission_fingerprint, :string)
    field(:session_ref, :string)
    field(:turn_ref, :string)
    field(:execution_target, :string)
    field(:phase, :string, default: "context_prepared")
    field(:milestones, Ryker.CanonicalJSON.Type, default: %{})
    field(:measurements, Ryker.CanonicalJSON.Type, default: %{})
    field(:response, Ryker.CanonicalJSON.Type)
    # Each answer host validation sent back before the accepted one, with why
    # (`Ryker.Admission.Attempts.reject/4`); the turns observed after it replace
    # `response`, so this is the only place it is kept.
    field(:rejections, Ryker.CanonicalJSON.Type)
    field(:operational_pruned_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
