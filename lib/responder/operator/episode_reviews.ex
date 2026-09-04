defmodule Responder.Operator.EpisodeReviews do
  @moduledoc """
  Append-only operator acknowledgement of one exact terminal episode version.

  A later semantic ending is reviewable again. Replays of the same local act
  return the existing receipt instead of rewriting who reviewed it.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Responder.Episodes.Episode
  alias Responder.Operator.EpisodeReview
  alias Responder.Repo

  @spec review(String.t(), String.t(), String.t()) ::
          {:ok, %{review: EpisodeReview.t(), status: :recorded | :duplicate}} | {:error, term()}
  def review(episode_key, actor_ref, note \\ "") do
    with :ok <- reference(episode_key, :episode_key),
         :ok <- reference(actor_ref, :actor_ref),
         :ok <- note(note) do
      Repo.transaction(fn -> review_locked(episode_key, actor_ref, note) end)
      |> transaction_result()
    end
  end

  defp review_locked(episode_key, actor_ref, note) do
    episode =
      Repo.one(from(episode in Episode, where: episode.key == ^episode_key, lock: "FOR UPDATE")) ||
        Repo.rollback(:episode_not_found)

    if episode.state not in [:complete, :cancelled], do: Repo.rollback(:episode_not_reviewable)

    case Repo.get_by(EpisodeReview,
           episode_id: episode.id,
           semantic_version: episode.semantic_version
         ) do
      %EpisodeReview{actor_ref: ^actor_ref, note: ^note} = review ->
        %{review: review, status: :duplicate}

      %EpisodeReview{} ->
        Repo.rollback(:episode_review_conflict)

      nil ->
        attributes = %{
          actor_ref: actor_ref,
          episode_id: episode.id,
          id: Ecto.UUID.generate(),
          note: note,
          reviewed_at: database_now!(),
          semantic_version: episode.semantic_version
        }

        case %EpisodeReview{}
             |> cast(attributes, [
               :actor_ref,
               :episode_id,
               :id,
               :note,
               :reviewed_at,
               :semantic_version
             ])
             |> validate_required([
               :actor_ref,
               :episode_id,
               :id,
               :reviewed_at,
               :semantic_version
             ])
             |> validate_length(:actor_ref, min: 1, max: 1_024)
             |> validate_length(:note, max: 2_048, count: :bytes)
             |> validate_number(:semantic_version, greater_than_or_equal_to: 0)
             |> unique_constraint([:episode_id, :semantic_version])
             |> foreign_key_constraint(:episode_id)
             |> check_constraint(:semantic_version, name: :episode_operator_review_valid)
             |> Repo.insert() do
          {:ok, review} -> %{review: review, status: :recorded}
          {:error, changeset} -> Repo.rollback({:episode_review_store, changeset.errors})
        end
    end
  end

  defp reference(value, _field)
       when is_binary(value) and byte_size(value) in 1..1_024 do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, :invalid_episode_review}
  end

  defp reference(_value, field), do: {:error, {:invalid_episode_review, field}}

  defp note(value) when is_binary(value) and byte_size(value) <= 2_048 do
    if String.valid?(value) and not String.contains?(value, <<0>>),
      do: :ok,
      else: {:error, {:invalid_episode_review, :note}}
  end

  defp note(_value), do: {:error, {:invalid_episode_review, :note}}

  defp database_now! do
    %Postgrex.Result{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
