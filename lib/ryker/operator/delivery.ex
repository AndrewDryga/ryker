defmodule Ryker.Operator.Delivery do
  @moduledoc """
  Trusted inspection and rearm surface for blocked delivery custody.

  It exposes only routing identifiers, retry state, and bounded error detail;
  frozen model output and platform credentials never cross this boundary.
  """

  import Ecto.Query

  alias Ryker.Delivery.{
    PlatformAction,
    PlatformActionCustody,
    RoutingResponse,
    RoutingResponseCustody
  }

  alias Ryker.{Reference, Repo}
  alias Ryker.WeeklyReport.Custody, as: ReportCustody
  alias Ryker.WeeklyReport.Report
  alias Ryker.Work.{Custody, Turn}

  # The Failures page reads as deep as the page it shows (a hundred a page).
  @maximum_list 10_001

  @doc """
  Blocked messages, routing responses, model-requested actions and weekly
  reports, newest first, `limit` in all.

  Each kind was read oldest first, so past `limit` the newest blocked replies,
  the ones people were still waiting on, were the ones never listed.
  """
  @spec list_blocked(pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_blocked(limit \\ 100) do
    if is_integer(limit) and limit > 0 and limit <= @maximum_list do
      messages =
        Repo.all(
          from(turn in Turn,
            where: turn.status == :blocked and not is_nil(turn.delivery_ref),
            order_by: [desc: turn.updated_at, desc: turn.id],
            limit: ^limit
          )
        )

      responses =
        Repo.all(
          from(response in RoutingResponse,
            where: response.status == :blocked,
            order_by: [desc: response.updated_at, desc: response.id],
            limit: ^limit
          )
        )

      actions =
        Repo.all(
          from(action in PlatformAction,
            where: action.status == :blocked,
            order_by: [desc: action.updated_at, desc: action.id],
            limit: ^limit
          )
        )

      reports = ReportCustody.blocked(limit)

      items =
        (Enum.map(messages, &message_item/1) ++
           Enum.map(responses, &response_item/1) ++
           Enum.map(actions, &action_item/1) ++ Enum.map(reports, &report_item/1))
        |> Enum.sort_by(&{DateTime.to_unix(&1.updated_at, :microsecond), &1.delivery_ref}, :desc)
        |> Enum.take(limit)

      {:ok, items}
    else
      {:error, {:invalid_delivery_operator, :limit}}
    end
  end

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(delivery_ref) do
    with :ok <- reference(delivery_ref),
         {:ok, {_kind, record}} <- lookup(delivery_ref) do
      {:ok, item(record)}
    end
  end

  @spec rearm(String.t()) :: {:ok, map()} | {:error, term()}
  def rearm(delivery_ref) do
    with :ok <- reference(delivery_ref),
         {:ok, target} <- lookup(delivery_ref),
         {:ok, record} <- rearm_target(target) do
      {:ok, item(record)}
    end
  end

  defp lookup(delivery_ref) do
    message = Repo.get_by(Turn, delivery_ref: delivery_ref)
    response = Repo.get_by(RoutingResponse, delivery_ref: delivery_ref)
    action = Repo.get_by(PlatformAction, action_ref: delivery_ref)
    report = ReportCustody.fetch(delivery_ref)

    case {message, response, action, report} do
      {%Turn{} = turn, nil, nil, nil} -> {:ok, {:message, turn}}
      {nil, %RoutingResponse{} = response, nil, nil} -> {:ok, {:routing, response}}
      {nil, nil, %PlatformAction{} = action, nil} -> {:ok, {:action, action}}
      {nil, nil, nil, %Report{} = report} -> {:ok, {:report, report}}
      {nil, nil, nil, nil} -> {:error, :delivery_not_found}
      _ambiguous -> {:error, :delivery_ref_ambiguous}
    end
  end

  defp rearm_target({:message, turn}) do
    Custody.retry_delivery(turn.episode_id, turn.turn_ref, turn.delivery_ref)
  end

  defp rearm_target({:routing, response}), do: RoutingResponseCustody.retry(response.delivery_ref)
  defp rearm_target({:action, action}), do: PlatformActionCustody.retry(action.action_ref)
  defp rearm_target({:report, report}), do: ReportCustody.retry(report.delivery_ref)

  defp item(%Turn{} = turn), do: message_item(turn)
  defp item(%RoutingResponse{} = response), do: response_item(response)
  defp item(%PlatformAction{} = action), do: action_item(action)
  defp item(%Report{} = report), do: report_item(report)

  defp message_item(turn) do
    %{
      attempt_count: turn.delivery_attempt_count,
      delivery_ref: turn.delivery_ref,
      episode_id: turn.episode_id,
      error_code: turn.last_error_code,
      error_detail: turn.last_error_detail,
      kind: :message,
      retry_generation: turn.delivery_retry_generation,
      status: turn.status,
      turn_ref: turn.turn_ref,
      updated_at: turn.updated_at
    }
  end

  defp response_item(response) do
    %{
      attempt_count: response.attempt_count,
      delivery_ref: response.delivery_ref,
      error_code: response.last_error_code,
      error_detail: response.last_error_detail,
      input_id: response.input_id,
      kind: if(response.kind == :message, do: :quick_reply, else: :reaction),
      retry_generation: response.retry_generation,
      status: response.status,
      updated_at: response.updated_at
    }
  end

  defp action_item(action) do
    %{
      attempt_count: action.attempt_count,
      delivery_ref: action.action_ref,
      episode_id: action.episode_id,
      error_code: action.last_error_code,
      error_detail: action.last_error_detail,
      kind: :platform_action,
      retry_generation: action.retry_generation,
      status: action.status,
      tool: action.tool,
      turn_id: action.turn_id,
      updated_at: action.updated_at
    }
  end

  # A weekly report belongs to no request: it names the channel it was for.
  defp report_item(report) do
    %{
      attempt_count: report.attempt_count,
      delivery_ref: report.delivery_ref,
      destination: report.conversation_ref,
      error_code: report.last_error_code,
      error_detail: report.last_error_detail,
      kind: if(report.preview, do: :weekly_report_preview, else: :weekly_report),
      retry_generation: report.retry_generation,
      status: report.status,
      updated_at: report.updated_at
    }
  end

  defp reference(value),
    do: Reference.check(value, :delivery_ref, :invalid_delivery_operator)
end
