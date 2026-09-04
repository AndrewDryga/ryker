defmodule Responder.ControlPlane.CardLabFeedback do
  @moduledoc """
  Append-only local review notes for one exact Card Lab specimen state.

  These notes never enter Slack or change runtime state. They are retained in
  PostgreSQL so an operator can iterate on the visual contract across normal
  Responder restarts.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Responder.ControlPlane.CardLab
  alias Responder.Repo

  @primary_key {:id, :binary_id, autogenerate: false}
  @verdicts ~w(needs_work good approved)

  schema "card_lab_feedback" do
    field(:actor_ref, :string)
    field(:card_id, :string)
    field(:state_id, :string)
    field(:verdict, :string)
    field(:note, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @spec record(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, t()} | {:error, term()}
  def record(card_id, state_id, verdict, note) do
    with {:ok, _snapshot} <- CardLab.fetch(card_id, state_id) do
      %__MODULE__{}
      |> cast(
        %{
          actor_ref: "control-plane:local",
          card_id: card_id,
          id: Ecto.UUID.generate(),
          note: note,
          state_id: state_id,
          verdict: verdict
        },
        [:actor_ref, :card_id, :id, :note, :state_id, :verdict]
      )
      |> validate_required([:actor_ref, :card_id, :id, :note, :state_id, :verdict])
      |> validate_length(:actor_ref, min: 1, max: 1_024)
      |> validate_length(:card_id, min: 1, max: 120)
      |> validate_length(:state_id, min: 1, max: 120)
      |> validate_length(:note, min: 1, max: 4_000, count: :bytes)
      |> validate_inclusion(:verdict, @verdicts)
      |> check_constraint(:note, name: :card_lab_feedback_valid)
      |> Repo.insert()
    end
  end

  @spec list(String.t(), String.t()) :: [t()]
  def list(card_id, state_id) when is_binary(card_id) and is_binary(state_id) do
    Repo.all(
      from(feedback in __MODULE__,
        where: feedback.card_id == ^card_id and feedback.state_id == ^state_id,
        order_by: [desc: feedback.inserted_at, desc: feedback.id],
        limit: 100
      )
    )
  end
end
