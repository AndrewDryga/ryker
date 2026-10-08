defmodule Ryker.Operator.Delivery do
  @moduledoc """
  Trusted inspection and rearm surface for blocked delivery custody.

  It exposes only routing identifiers, retry state, and bounded error detail;
  frozen model output and platform credentials never cross this boundary.
  """
  alias Ryker.Delivery
  alias Ryker.{Reference, Repo}
  alias Ryker.WeeklyReport
  alias Ryker.Work

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
        Work.Turn.Query.blocked_deliveries()
        |> Work.Turn.Query.ordered_by_recently_updated()
        |> Work.Turn.Query.limit_to(limit)
        |> Repo.all()

      responses =
        Delivery.RoutingResponse.Query.all()
        |> Delivery.RoutingResponse.Query.by_status(:blocked)
        |> Delivery.RoutingResponse.Query.ordered_by_recently_updated()
        |> Delivery.RoutingResponse.Query.limit_to(limit)
        |> Repo.all()

      actions =
        Delivery.PlatformAction.Query.all()
        |> Delivery.PlatformAction.Query.by_status(:blocked)
        |> Delivery.PlatformAction.Query.ordered_by_recently_updated()
        |> Delivery.PlatformAction.Query.limit_to(limit)
        |> Repo.all()

      reports = WeeklyReport.Custody.blocked(limit)

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
    message = Repo.one(Work.Turn.Query.by_delivery_ref(delivery_ref))
    response = Repo.one(Delivery.RoutingResponse.Query.by_delivery_ref(delivery_ref))
    action = Repo.one(Delivery.PlatformAction.Query.by_action_ref(delivery_ref))
    report = Repo.one(WeeklyReport.Report.Query.by_delivery_ref(delivery_ref))

    case {message, response, action, report} do
      {%Work.Turn{} = turn, nil, nil, nil} -> {:ok, {:message, turn}}
      {nil, %Delivery.RoutingResponse{} = response, nil, nil} -> {:ok, {:routing, response}}
      {nil, nil, %Delivery.PlatformAction{} = action, nil} -> {:ok, {:action, action}}
      {nil, nil, nil, %WeeklyReport.Report{} = report} -> {:ok, {:report, report}}
      {nil, nil, nil, nil} -> {:error, :delivery_not_found}
      _ambiguous -> {:error, :delivery_ref_ambiguous}
    end
  end

  defp rearm_target({:message, turn}) do
    Work.Custody.retry_delivery(turn.episode_id, turn.turn_ref, turn.delivery_ref)
  end

  defp rearm_target({:routing, response}),
    do: Delivery.RoutingResponseCustody.retry(response.delivery_ref)

  defp rearm_target({:action, action}),
    do: Delivery.PlatformActionCustody.retry(action.action_ref)

  defp rearm_target({:report, report}), do: WeeklyReport.Custody.retry(report.delivery_ref)

  defp item(%Work.Turn{} = turn), do: message_item(turn)
  defp item(%Delivery.RoutingResponse{} = response), do: response_item(response)
  defp item(%Delivery.PlatformAction{} = action), do: action_item(action)
  defp item(%WeeklyReport.Report{} = report), do: report_item(report)

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
      held: response |> Delivery.RoutingResponse.Query.held_behind() |> Repo.aggregate(:count),
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
      held: held_behind(action),
      kind: :platform_action,
      retry_generation: action.retry_generation,
      status: action.status,
      tool: action.tool,
      turn_id: action.turn_id,
      updated_at: action.updated_at
    }
  end

  # A blocked reaction or update holds back the later ones of its kind in its
  # turn, which wait in order behind it; other actions hold back nothing.
  defp held_behind(%Delivery.PlatformAction{tool: tool} = action) do
    if tool in Delivery.PlatformActionCustody.numbered_tools(),
      do: action |> Delivery.PlatformAction.Query.held_behind() |> Repo.aggregate(:count),
      else: 0
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
