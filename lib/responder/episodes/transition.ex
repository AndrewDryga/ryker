defmodule Responder.Episodes.Transition do
  @moduledoc false
  alias Responder.Episodes.{Episode, Event}

  @enforce_keys [:episode, :event, :status]
  defstruct @enforce_keys

  @type t :: %__MODULE__{episode: Episode.t(), event: Event.t(), status: :applied | :duplicate}
end
