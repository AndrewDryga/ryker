defmodule Ryker.CoopFleet.ModelImportReceipt do
  @moduledoc false
  use Ryker, :schema

  schema "coop_model_import_receipts" do
    field(:account, :string)
  end
end
