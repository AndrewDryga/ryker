defmodule Ryker.ControlPlane.ConfigurationGuide do
  @moduledoc false

  def description(:rules) do
    "Rules tell Ryker to act when something happens, like a new alert or a merged pull request."
  end

  def description(:memory) do
    "Things people told Ryker to remember. It uses them as context, and they don't give it permission to act."
  end

  def description(:learned),
    do: "What Ryker learned by reading conversations, with the messages it learned from."

  def description(:learning),
    do: "Ryker reads conversations in the background and keeps what it learned up to date."

  def description(:instructions),
    do: "How Ryker should work. It follows these in every reply, investigation and task."

  def description(:findings),
    do: "Conclusions Ryker reached in investigations, with the evidence behind them."

  def description(:people) do
    "What people said about themselves, such as a birthday or the name they go by. Ryker uses it to be considerate to them."
  end
end
