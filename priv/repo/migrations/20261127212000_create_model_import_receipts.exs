defmodule Ryker.Repo.Migrations.CreateModelImportReceipts do
  use Ecto.Migration

  def change do
    create table(:coop_model_import_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:account, :text, null: false)
    end
  end
end
