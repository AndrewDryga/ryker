defmodule Ryker.Settings.Work do
  @moduledoc """
  Where Work runs and on which models.

  The workspace names an enrolled worker workspace; a browser never invents
  one. Each kind of work the bundled worker runs has its own model: routing,
  conversation, standard, deep and contributor work, schedules, incident rooms
  and learning. `ready_routing_sessions` is how many routing sessions Ryker
  starts ahead of time (`Ryker.Admission.ReadyPool`); 0 turns that off.
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
  @fields [:workspace_ref, :ready_routing_sessions | @model_fields]
  @maximum_ready_routing_sessions 5

  schema "work_settings" do
    field(:workspace_ref, :string)
    field(:ready_routing_sessions, :integer, default: 1)

    for {name, default} <- @models do
      field(name, :string, default: default)
    end
  end

  def fields, do: @fields
  def model_fields, do: @model_fields
  def maximum_ready_routing_sessions, do: @maximum_ready_routing_sessions

  def changeset(current, attributes, _snapshot) do
    current
    |> cast(attributes, @fields)
    |> validate_length(:workspace_ref, min: 1, max: 256)
    |> validate_required([:ready_routing_sessions | @model_fields])
    |> validate_number(:ready_routing_sessions,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: @maximum_ready_routing_sessions
    )
    |> check_constraint(:ready_routing_sessions,
      name: :work_settings_ready_routing_sessions_valid
    )
    |> then(fn changeset ->
      Enum.reduce(@model_fields, changeset, &validate_format(&2, &1, @target))
    end)
  end
end
