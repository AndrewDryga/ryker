defmodule Ryker.Settings.Work do
  @moduledoc """
  Where Work runs and on which models.

  The workspace names an enrolled worker workspace; a browser never invents
  one. Each kind of work the bundled worker runs has its own model: routing,
  conversation, standard, deep and contributor work, schedules, incident rooms
  and learning.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  # The bundled worker runs Codex, which takes these four reasoning efforts.
  @target ~r/\Acodex:[a-z0-9][a-z0-9._-]{0,63}\/(low|medium|high|xhigh)@[a-z0-9][a-z0-9_-]{0,63}\z/
  @models [
    routing_model: "codex:gpt-5.6-sol/medium@default",
    conversation_model: "codex:gpt-5.6-terra/medium@default",
    standard_model: "codex:gpt-5.6-sol/medium@default",
    deep_model: "codex:gpt-5.6-sol/xhigh@default",
    contributor_model: "codex:gpt-5.6-sol/medium@default",
    schedule_model: "codex:gpt-5.6-sol/medium@default",
    incident_model: "codex:gpt-5.6-sol/medium@default",
    learning_model: "codex:gpt-5.6-sol/medium@default"
  ]
  @model_fields Keyword.keys(@models)
  @fields [:workspace_ref | @model_fields]

  schema "work_settings" do
    field(:workspace_ref, :string)

    for {name, default} <- @models do
      field(name, :string, default: default)
    end
  end

  def fields, do: @fields
  def model_fields, do: @model_fields

  def changeset(current, attributes, _snapshot) do
    current
    |> cast(attributes, @fields)
    |> validate_length(:workspace_ref, min: 1, max: 256)
    |> validate_required(@model_fields)
    |> then(fn changeset ->
      Enum.reduce(@model_fields, changeset, &validate_format(&2, &1, @target))
    end)
  end
end
