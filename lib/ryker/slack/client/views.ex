defmodule Ryker.Slack.Client.Views do
  @moduledoc """
  Views: the App Home a person sees on Ryker's own tab, and the modal a
  button opens.

  Each view is checked for exactly the fields its kind carries, a bounded
  number of blocks and a bounded size before it is sent, and a reply that
  does not describe a view of the same kind is a protocol error.
  """
  alias Ryker.Slack.Client.{Fields, Transport}

  def publish_home(client, user_ref, view) do
    with :ok <- Fields.slack_id(user_ref),
         :ok <- home_view(view),
         {:ok, response} <-
           Transport.request(client, :post, "/views.publish", %{
             "user_id" => user_ref,
             "view" => view
           }),
         {:ok, body} <- Transport.response(response),
         %{"view" => %{"type" => "home"}} <- body do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, {:slack_protocol_error, :home_view}}
    end
  end

  def open_view(client, trigger_ref, view) do
    with :ok <- Fields.bounded_text(trigger_ref, 256),
         :ok <- modal_view(view),
         {:ok, response} <-
           Transport.request(client, :post, "/views.open", %{
             "trigger_id" => trigger_ref,
             "view" => view
           }),
         {:ok, body} <- Transport.response(response),
         %{"view" => %{"type" => "modal"}} <- body do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, {:slack_protocol_error, :modal_view}}
    end
  end

  # A view Slack publishes to the App Home: exactly `blocks` and `type`, bounded.
  defp home_view(%{"blocks" => blocks, "type" => "home"} = view)
       when is_list(blocks) and length(blocks) <= 100 do
    if Map.keys(view) |> Enum.sort() == ["blocks", "type"] and
         Enum.all?(blocks, &is_map/1) and byte_size(Jason.encode!(view)) <= 256 * 1_024,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :home_view}}
  end

  defp home_view(_view), do: {:error, {:invalid_slack_api_request, :home_view}}

  defp modal_view(%{"blocks" => blocks, "type" => "modal"} = view)
       when is_list(blocks) and length(blocks) <= 100 do
    required = ~w(blocks callback_id close private_metadata submit title type)

    if Map.keys(view) |> Enum.sort() == Enum.sort(required) and
         Enum.all?(blocks, &is_map/1) and byte_size(Jason.encode!(view)) <= 256 * 1_024,
       do: :ok,
       else: {:error, {:invalid_slack_api_request, :modal_view}}
  end

  defp modal_view(_view), do: {:error, {:invalid_slack_api_request, :modal_view}}
end
