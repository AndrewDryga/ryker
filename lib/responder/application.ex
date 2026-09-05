defmodule Responder.Application do
  @moduledoc false
  use Application

  @impl Application
  def start(_type, _args) do
    :ok = Responder.RuntimeConfiguration.install_from_env!()

    children =
      [
        Responder.Repo,
        {Finch, name: Responder.CoopFinch},
        {Phoenix.PubSub, name: Responder.ControlPlane.PubSub}
      ] ++
        admission_children() ++
        work_children() ++
        retention_children() ++
        github_children() ++
        publication_children() ++
        delivery_children() ++
        state_tools_children() ++
        emisar_approval_children() ++
        event_wait_children() ++
        schedule_children() ++
        slack_children() ++
        webhook_children() ++ coop_worker_gateway_children() ++ control_plane_children()

    Supervisor.start_link(children, name: Responder.Supervisor, strategy: :one_for_one)
  end

  defp admission_children do
    optional_child(:admission, Responder.Admission.Runtime)
  end

  defp work_children do
    optional_child(:work, Responder.Work.Runtime)
  end

  defp retention_children do
    optional_child(:retention, Responder.Retention.Runtime)
  end

  defp delivery_children do
    optional_child(:delivery, Responder.Delivery.Runtime)
  end

  defp publication_children do
    optional_child(:publication, Responder.Publication.Runtime)
  end

  defp state_tools_children do
    optional_child(:state_tools, Responder.StateTools.Server)
  end

  defp emisar_approval_children do
    optional_child(:emisar, Responder.Emisar.ApprovalRuntime)
  end

  defp slack_children do
    optional_child(:slack, Responder.Slack.Runtime)
  end

  defp event_wait_children do
    optional_child(:event_waits, Responder.State.EventWaitWorker)
  end

  defp schedule_children do
    optional_child(:schedules, Responder.State.ScheduleRuntime)
  end

  defp webhook_children do
    optional_child(:webhooks, Responder.Webhooks.Server)
  end

  defp github_children do
    optional_child(:github, Responder.GitHub.Runtime)
  end

  defp control_plane_children do
    case optional_child(:control_plane, Responder.ControlPlane.Server) do
      [] ->
        []

      children ->
        [
          {Responder.ControlPlane.Updates, []},
          {Responder.ControlPlane.CardLabWorker, []} | children
        ]
    end
  end

  defp coop_worker_gateway_children do
    optional_child(:coop_worker_gateway, Responder.CoopFleet.Server)
  end

  defp optional_child(configuration_key, module) do
    case Application.get_env(:responder, configuration_key) do
      nil -> []
      false -> []
      configuration -> [{module, configuration}]
    end
  end
end
