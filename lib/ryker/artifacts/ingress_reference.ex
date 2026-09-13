defmodule Ryker.Artifacts.IngressReference do
  @moduledoc false

  use Ecto.Schema

  alias Ryker.Artifacts.Artifact
  alias Ryker.Ingress.Inbox.Entry

  @primary_key false
  schema "ingress_input_artifact_references" do
    belongs_to(:input, Entry, type: :binary_id, primary_key: true)
    belongs_to(:artifact, Artifact, type: :binary_id, primary_key: true)

    timestamps(type: :utc_datetime_usec)
  end
end
