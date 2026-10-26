defmodule Ryker.Slack.Renderer.MonitoringFooter do
  @moduledoc "The native and accessible versions of the same host-owned follow-up receipt."
  import Ryker.Slack.Renderer.Blocks
  import Ryker.Slack.Renderer.Fields
  alias Ryker.Maps
  alias Ryker.Wording

  @states ~w(waiting checking failed cancelled ended stopped reply replied)

  def render(status) do
    with :ok <- validate(status), do: {:ok, [context(text(status))]}
  end

  defp validate(status) when is_map(status) do
    with true <- Maps.only_keys?(status, ~w(checks last_check_at state next_check_at history_url)),
         true <- map_size(status) == 5,
         true <- is_integer(status["checks"]) and status["checks"] in 0..1_000_000,
         true <- status["state"] in @states,
         :ok <- optional_time(status["last_check_at"]),
         :ok <- optional_time(status["next_check_at"]),
         :ok <- optional_https_url(status["history_url"]),
         true <- is_nil(status["next_check_at"]) or status["state"] == "waiting" do
      :ok
    else
      _ -> {:error, {:invalid_slack_render, :monitoring}}
    end
  end

  defp validate(_status), do: {:error, {:invalid_slack_render, :monitoring}}

  def text(status, native? \\ true) do
    checks = status["checks"]
    count = Wording.count(checks, "check") <> " completed"
    time = fn at -> if native?, do: slack_date(at), else: display_time(at) end

    [
      count,
      status["last_check_at"] && "Last checked #{time.(status["last_check_at"])}",
      label(status["state"], checks),
      status["next_check_at"] && "Next check #{time.(status["next_check_at"])}",
      status["history_url"] &&
        if(native?,
          do: link(status["history_url"], "View checks"),
          else: "View checks: #{status["history_url"]}"
        )
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp label("waiting", 0), do: "Monitoring scheduled"
  defp label("waiting", _checks), do: "No new reply needed"
  defp label("checking", _checks), do: "Check pending"
  defp label("failed", _checks), do: "Couldn't complete the latest check"
  defp label("cancelled", _checks), do: "Monitoring cancelled"
  defp label("ended", _checks), do: "Monitoring ended"
  defp label("stopped", _checks), do: "Monitoring no longer active"
  defp label("reply", _checks), do: "Follow-up reply prepared"
  defp label("replied", _checks), do: "Follow-up posted"

  defp optional_time(nil), do: :ok
  defp optional_time(at), do: iso8601(at)
end
