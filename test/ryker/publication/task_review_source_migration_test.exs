defmodule Ryker.Publication.TaskReviewSourceMigrationTest do
  use Ryker.MigrationCase
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.Publication

  @version 20_261_030_180_000

  test "message-free task reviews become possible without rewriting retained source messages" do
    %{publication: publication} = PublicationFixture.review_requested!("source-message-migration")
    source_message = publication.offer_message_ref
    assert is_binary(source_message)
    assert migrate_down(@version) == :ok

    assert {:error, %Postgrex.Error{postgres: %{code: :not_null_violation}}} =
             clear_source(publication)

    assert migrate_up(@version) == :ok
    assert Repo.get!(Publication, publication.id).offer_message_ref == source_message
    assert {:ok, %{offer_message_ref: nil}} = clear_source(publication)
  end

  defp clear_source(publication) do
    Repo.transaction(fn ->
      publication |> Ecto.Changeset.change(offer_message_ref: nil) |> Repo.update!()
    end)
  rescue
    error in Postgrex.Error -> {:error, error}
  end
end
