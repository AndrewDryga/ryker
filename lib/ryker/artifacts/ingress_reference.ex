defmodule Ryker.Artifacts.IngressReference do
  @moduledoc false
  use Ryker, :schema
  alias Ryker.Artifacts.Artifact
  alias Ryker.Ingress

  @primary_key false
  schema "ingress_input_artifact_references" do
    belongs_to(:input, Ingress.Inbox.Entry, type: :binary_id, primary_key: true)
    belongs_to(:artifact, Artifact, type: :binary_id, primary_key: true)

    timestamps()
  end
end
