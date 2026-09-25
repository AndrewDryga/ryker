defmodule Ryker.ControlPlane.ConfigurationGuide do
  @moduledoc false

  def description(:rules),
    do:
      "Rules tell Ryker to act when something happens, like a new alert or a merged pull request."

  def description(:memory),
    do: "Things people told Ryker to remember. Ryker uses them as context, never as permission."

  def description(:learned),
    do: "What Ryker learned by reading conversations, with the messages it learned from."

  def description(:learning),
    do:
      "Ryker reads conversations in the background and keeps what it learned up to date. Learning never sends a reply."

  def description(:instructions),
    do: "How Ryker should work. It follows these in every reply, investigation and task."

  def description(:findings),
    do: "Conclusions Ryker reached in investigations, with the evidence behind them."
end
