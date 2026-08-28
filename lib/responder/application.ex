defmodule Responder.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    children =
      [Responder.Repo, {Finch, name: Responder.CoopFinch}] ++
        admission_children() ++ webhook_children()

    Supervisor.start_link(children, name: Responder.Supervisor, strategy: :one_for_one)
  end

  defp admission_children do
    optional_child(:admission, Responder.Admission.Runtime)
  end

  defp webhook_children do
    optional_child(:webhooks, Responder.Webhooks.Server)
  end

  defp optional_child(configuration_key, module) do
    case Application.get_env(:responder, configuration_key) do
      nil -> []
      false -> []
      configuration -> [{module, configuration}]
    end
  end
end
