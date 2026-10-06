defmodule Ryker.ControlPlane.LocalRoutingPage do
  @moduledoc """
  The local routing model's own page, under Settings › Models beside its
  setting: how the model you run yourself would have routed the live
  messages the provider model routed (`Ryker.LocalRouting`), built only from
  Kit parts. It lived on Usage & cost until Andrew asked, 2026-10-03, "why
  the fuck you added Local routing model and Where it decided differently to
  usage and costs?!"

  A status line says where the comparison stands (a dot and a word, the
  model, and the way to its setting), then a period switch, then the
  figures for the period: comparisons run, the share of answers routing's
  checks took (valid) and the share that decided what the provider decided
  (agreed), the median time the local model took beside the provider's, and
  what the provider spent on those messages, which is what a cascade would
  save on each message the local model gets right. Three tables follow: by
  what the provider decided, how many of the local model's answers were
  usable and matched; what differed when a usable answer did not match; and
  why routing refused the rest. Each row links to its latest message, opened
  at the routing step.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Kit, Paths, ShortTime}
  alias Ryker.LocalRouting
  alias Ryker.Settings

  @setting "/settings/models#local-routing"
  @path "/settings/models/local-routing"
  @windows [{"24h", "24 hours"}, {"7d", "7 days"}, {"30d", "30 days"}, {"all", "All time"}]

  @doc "Where the page is."
  def path, do: @path

  @doc "The sentence under the page's title."
  def description,
    do:
      "How the small model you run yourself would have routed live messages, compared with " <>
        "the provider model. Routing doesn't use its answers."

  @doc """
  The topics an open page listens to: comparisons queued and settled, and
  the settings, which hold the model it compares.
  """
  def subscriptions,
    do: [{LocalRouting, :subscribe_comparisons, []}, {Settings, :subscribe, []}]

  @doc "The page's body for one period (`24h`, `7d`, `30d` or `all`)."
  @spec render(map(), String.t()) :: iodata()
  def render(summary, window) do
    %{__changed__: nil, summary: summary, window: window}
    |> page()
    |> Safe.to_iodata()
  end

  attr(:summary, :map, required: true)
  attr(:window, :string, required: true)

  defp page(assigns) do
    %{setting: setting, figures: figures} = assigns.summary

    assigns =
      assign(assigns,
        decisions: assigns.summary.decisions,
        differences: assigns.summary.differences,
        refusals: assigns.summary.refusals,
        now: DateTime.utc_now(),
        link:
          if(setting.mode == :shadow, do: "Change it", else: "Turn it on") <>
            " in Settings › Models",
        model: setting.mode == :shadow && setting.model,
        primary: primary(figures),
        secondary: secondary(figures),
        setting_href: @setting,
        state: state(setting.mode, assigns.summary.last_settled),
        windows:
          Enum.map(@windows, fn {key, label} ->
            {label, @path <> "?window=" <> key, key == assigns.window}
          end)
      )

    ~H"""
    <div id="local-routing" class="local-routing-page">
      <Kit.status_line state={@state}>
        <span :if={@model}>{@model}</span>
        <a href={@setting_href}>{@link}</a>
      </Kit.status_line>
      <Kit.toolbar>
        <Kit.segmented label="Period" options={@windows} />
      </Kit.toolbar>
      <Kit.section_card
        id="local-routing-figures"
        title="How it compares"
        lede="How the local model did on the live messages routed in this period."
      >
        <Kit.counts :if={@primary != []} items={@primary} label="How it compares" />
        <Kit.counts
          :if={@secondary != []}
          items={@secondary}
          label="How it compares, in more detail"
          secondary
        />
        <Kit.empty
          :if={@primary == [] and @secondary == []}
          variant={:hint}
          icon={:clock}
          title="Nothing compared in this period"
          text="Each message routed while the comparison is on is counted here."
        />
      </Kit.section_card>
      <Kit.section_card
        :if={@decisions != []}
        id="local-routing-decisions"
        title="By what the provider decided"
        lede="For each kind of decision the provider made, how often the local model's answer was usable and matched it."
      >
        <Kit.table label="By what the provider decided" rows={@decisions}>
          <:col :let={row} label="The provider chose">{row.name}</:col>
          <:col :let={row} label="Messages" numeric>{row.messages}</:col>
          <:col :let={row} label="Usable answers" numeric>{row.valid}</:col>
          <:col :let={row} label="Matched" numeric>{row.agreed}</:col>
          <:col :let={row} label="When it differed, it chose">{row.instead || "—"}</:col>
          <:col :let={row} label="Latest" numeric><.latest row={row.latest} now={@now} /></:col>
        </Kit.table>
      </Kit.section_card>
      <Kit.section_card
        :if={@differences != []}
        id="local-routing-differences"
        title="What differed"
        lede="Where its usable answers differed from the provider's."
      >
        <Kit.table label="What differed" rows={@differences}>
          <:col :let={row} label="What differed">{row.name}</:col>
          <:col :let={row} label="Answers" numeric>{row.answers}</:col>
          <:col :let={row} label="The only difference" numeric>{row.only}</:col>
          <:col :let={row} label="Latest" numeric><.latest row={row.latest} now={@now} /></:col>
        </Kit.table>
      </Kit.section_card>
      <Kit.section_card
        :if={@refusals != []}
        id="local-routing-refused"
        title="Why routing refused its answers"
        lede="Answers that failed routing's checks, so routing couldn't have used them."
      >
        <Kit.table label="Why routing refused its answers" rows={@refusals}>
          <:col :let={row} label="The local model">{row.name}</:col>
          <:col :let={row} label="Answers" numeric>{row.answers}</:col>
          <:col :let={row} label="Latest" numeric><.latest row={row.latest} now={@now} /></:col>
        </Kit.table>
      </Kit.section_card>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:now, :any, required: true)

  # The latest message a row is about, by when it was routed, opened at its
  # routing step.
  defp latest(assigns) do
    ~H"""
    <a href={latest_href(@row)}>{ShortTime.text(@row.at, @now)}</a>
    """
  end

  # The message a row is about, opened at its routing step.
  defp latest_href(row),
    do: Paths.request(row.input_id) <> "#admission-#{row.input_id}-#{row.generation}"

  defp state(:off, _last), do: {:off, "Off"}

  defp state(:shadow, %{status: :failed, last_error: why}),
    do: {:warn, "Not reaching the local model", why}

  defp state(:shadow, _last), do: {:on, "Comparing"}

  defp primary(%{compared: 0}), do: []

  defp primary(figures) do
    [
      %{
        value: number(figures.compared),
        label: plural(figures.compared, "comparison", "comparisons")
      },
      %{value: percent(figures.valid, figures.compared), label: "valid"},
      %{value: percent(figures.agreed, figures.compared), label: "agreed with the provider"},
      %{value: duration(figures.local_ms), label: "median local time"},
      %{
        value: money(figures.provider_cost, figures.estimated),
        label: "provider cost of these messages"
      }
    ]
  end

  defp secondary(figures) do
    [
      figures.compared > 0 and
        %{value: duration(figures.provider_ms), label: "median provider time"},
      figures.compared > 0 and
        %{
          value: money(figures.agreed_cost, figures.estimated),
          label: "of it on messages the local model agreed on"
        },
      figures.waiting > 0 and %{value: number(figures.waiting), label: "waiting"},
      figures.failed > 0 and
        %{value: number(figures.failed), label: "could not be asked", tone: :warn}
    ]
    |> Enum.filter(& &1)
  end

  defp plural(1, one, _many), do: one
  defp plural(_count, _one, many), do: many

  defp number(n), do: n |> to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  defp percent(_part, 0), do: "—"
  defp percent(part, whole), do: decimal(part / whole * 100) <> "%"

  # The Usage page's own formats: seconds to one decimal, dollars to the cent
  # or, below a cent, to four places, and ≈ for an estimate.
  defp duration(nil), do: "—"
  defp duration(ms) when ms >= 3_600_000, do: decimal(ms / 3_600_000) <> "h"
  defp duration(ms) when ms >= 60_000, do: decimal(ms / 60_000) <> "m"
  defp duration(ms), do: decimal(ms / 1_000) <> "s"

  defp money(nil, _estimated), do: "Not measured"
  defp money(%Decimal{coef: 0}, _estimated), do: "$0"

  defp money(%Decimal{} = cost, estimated) do
    precision =
      if Decimal.compare(cost, 0) == :gt and Decimal.compare(cost, Decimal.new("0.01")) == :lt,
        do: 4,
        else: 2

    if(estimated, do: "≈ $", else: "$") <>
      Decimal.to_string(Decimal.round(cost, precision), :normal)
  end

  defp decimal(n), do: :erlang.float_to_binary(n * 1.0, decimals: 1) |> String.trim_trailing(".0")
end
