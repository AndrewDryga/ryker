defmodule Ryker.Episodes.Words do
  @moduledoc """
  The words every surface uses for a request's states and lifecycle: the
  control plane's pages and the Slack work record read the same ones. The
  kernel's own names ("owner transferred", "wait resumed") stay in the code
  and the logs.
  """
  alias Ryker.Wording

  @doc """
  A state, decision or stored name in words. States arrive as the strings the
  projections cast and as the atoms the schemas hold; both name the same word.
  """
  @spec label(term()) :: String.t()
  def label(value) when is_atom(value) and not is_nil(value), do: label(Atom.to_string(value))
  def label("pending"), do: "Queued"
  def label("routing"), do: "Routing"
  def label("working"), do: "Working"
  def label("not_started"), do: "Couldn't start"
  def label("delivery_pending"), do: "Sending reply"
  def label("waiting_for_input"), do: "Needs your input"
  def label("waiting_for_event"), do: "Waiting for an event"
  def label("blocked"), do: "Needs attention"
  def label("complete"), do: "Completed"
  def label("cancelled"), do: "Stopped"
  def label("superseded"), do: "Replaced by an edit"
  def label("ignore"), do: "No response needed"
  def label("react"), do: "Reaction selected"
  def label("quick_reply"), do: "Answered right away"
  def label("reply"), do: "Reply selected"
  def label(value), do: Wording.label(value)

  @doc "What one kernel transition means to the person whose request it is."
  @spec lifecycle_title(atom()) :: String.t()
  def lifecycle_title(:input_admitted), do: "Message added"
  def lifecycle_title(:owner_transferred), do: "Handed to a new run"
  def lifecycle_title(:input_wait_started), do: "Waiting for an answer"
  def lifecycle_title(:event_wait_started), do: "Waiting for an event"
  def lifecycle_title(:wait_resumed), do: "Picked up again after waiting"
  def lifecycle_title(:result_accepted), do: "Answer accepted"
  def lifecycle_title(:delivery_confirmed), do: "Delivery confirmed"
  def lifecycle_title(:episode_cancelled), do: "Request stopped"
  def lifecycle_title(:reaction_recorded), do: "Reaction recorded"
  def lifecycle_title(_kind), do: "Request updated"
end
