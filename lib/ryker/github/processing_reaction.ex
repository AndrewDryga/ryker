defmodule Ryker.GitHub.ProcessingReaction do
  @moduledoc "Durable custody of the App's temporary eyes on one GitHub comment."
  use Ryker, :schema

  schema "github_processing_reactions" do
    field(:binding, :string)
    field(:repository_id, :integer)
    field(:actor_id, :integer)
    field(:comment_kind, :string)
    field(:comment_id, :integer)
    field(:desired, :boolean, default: true)
    field(:reaction_id, :integer)
    field(:uncertain, :boolean, default: false)
    field(:blocked, :boolean, default: false)
    field(:attempt_count, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:lease_ref, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
