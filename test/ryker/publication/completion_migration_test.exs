defmodule Ryker.Publication.CompletionMigrationTest do
  use Ryker.MigrationCase
  alias Ryker.Fixtures.Publication, as: PublicationFixture
  alias Ryker.Publication.Publication

  @version 20_261_117_210_000
  @notifications [
    :review_delivery_receipt,
    :review_delivery_receipt_fingerprint,
    :published_delivery_receipt,
    :published_delivery_receipt_fingerprint
  ]

  # A task used to need fabricated external delivery receipts to get past
  # notification phases. Relax only those receipts, never the review or push.
  test "task outcomes need no chat receipt while retained publication evidence survives" do
    %{publication: manual} = PublicationFixture.published!("completion-migration-manual")
    %{publication: task} = PublicationFixture.published!("completion-migration-task")

    task =
      task
      |> Ecto.Changeset.change(review_request_ref: "task-readiness:#{Ecto.UUID.generate()}")
      |> Repo.update!()

    assert migrate_down(@version) == :ok
    assert_raise Ecto.ConstraintError, fn -> clear_notifications(task) end
    assert migrate_up(@version) == :ok
    assert Repo.get!(Publication, task.id) == task
    assert Repo.get!(Publication, manual.id) == manual
    assert {:ok, cleared} = clear_notifications(task)
    assert Enum.all?(@notifications, &is_nil(Map.fetch!(cleared, &1)))
    assert cleared.publication_receipt == task.publication_receipt
    assert cleared.review_document == task.review_document
    assert cleared.publication_receipt_fingerprint == task.publication_receipt_fingerprint
    assert_raise Ecto.ConstraintError, fn -> clear_notifications(manual) end

    assert_raise Ecto.ConstraintError, fn ->
      Repo.transaction(fn ->
        cleared
        |> Ecto.Changeset.change(
          publication_receipt: nil,
          publication_receipt_fingerprint: nil,
          published_at: nil
        )
        |> Repo.update!()
      end)
    end
  end

  defp clear_notifications(publication) do
    Repo.transaction(fn ->
      publication |> Ecto.Changeset.change(Map.new(@notifications, &{&1, nil})) |> Repo.update!()
    end)
  end
end
