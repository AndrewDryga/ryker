defmodule Ryker.ControlPlane.EpisodeTrace.Step do
  @moduledoc """
  The shape of one timeline step and the small vocabulary every chapter of
  the trace shares: bounded text, human labels, durations and reference
  formatting. Chapters `import` this module; nothing here reads the database.
  """

  def step(id, band, at, attributes) do
    %{
      actor: human(Map.fetch!(attributes, :actor)),
      input_id: Map.get(attributes, :input_id),
      owner: Map.get(attributes, :owner, :episode),
      rules: Map.get(attributes, :rules),
      participation: Map.get(attributes, :participation),
      engagement: Map.get(attributes, :engagement),
      queue: Map.get(attributes, :queue),
      setup: Map.get(attributes, :setup),
      record_ref: Map.get(attributes, :record_ref),
      result_ref: Map.get(attributes, :result_ref),
      delivery_ref: Map.get(attributes, :delivery_ref),
      artifacts: Map.get(attributes, :artifacts, []),
      current_warning: Map.get(attributes, :current_warning),
      at: at,
      band: band,
      details: Map.fetch!(attributes, :details),
      duration_ms: Map.get(attributes, :duration_ms),
      tool_kind: Map.get(attributes, :tool_kind),
      path_context: Map.get(attributes, :path_context),
      href: Map.get(attributes, :href),
      id: id,
      stage: human(Map.fetch!(attributes, :stage)),
      # A step whose badge would only restate its own title carries no state at
      # all, rather than a word the reader has already read.
      state: attributes |> Map.get(:state) |> optional_human(),
      summary: present(Map.fetch!(attributes, :summary)),
      title: present(Map.fetch!(attributes, :title)),
      tone: Map.get(attributes, :tone)
    }
  end

  def compact_details(values) do
    values
    |> Enum.flat_map(fn
      {_label, nil} -> []
      {_label, ""} -> []
      {label, %DateTime{} = value} -> [%{label: label, value: DateTime.to_iso8601(value)}]
      {label, value} -> [%{label: label, value: bounded(to_string(value), 1_024)}]
    end)
    |> Enum.take(20)
  end

  def bounded_strings(values) when is_list(values) do
    values |> Enum.filter(&is_binary/1) |> Enum.map(&bounded(&1, 512)) |> Enum.take(16)
  end

  def bounded_strings(_values), do: []

  def bounded(value, maximum) when byte_size(value) <= maximum, do: value
  def bounded(value, maximum), do: String.slice(value, 0, maximum) <> "…"

  def short_digest(value) when is_binary(value) and byte_size(value) > 12,
    do: binary_part(value, 0, 12) <> "…"

  def short_digest(value) when is_binary(value), do: value
  def short_digest(_value), do: nil

  def join_ref(nil, nil), do: nil

  def join_ref(kind, ref),
    do: [kind, ref] |> Enum.reject(&is_nil/1) |> Enum.map_join(":", &to_string/1)

  def elapsed(%DateTime{} = left, %DateTime{} = right),
    do: format_ms(max(DateTime.diff(right, left, :millisecond), 0))

  def elapsed(_left, _right), do: "unmeasured"

  def relative(%DateTime{} = at, %DateTime{} = started_at),
    do: "+" <> format_ms(max(DateTime.diff(at, started_at, :millisecond), 0))

  def relative(_at, _started_at), do: nil

  def time_key(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  def time_key(_value), do: 9_223_372_036_854_775_807

  def format_ms(nil), do: nil
  def format_ms(value) when value < 1_000, do: "#{value} ms"
  def format_ms(value) when value < 60_000, do: format_decimal(value / 1_000, "s")
  def format_ms(value) when value < 3_600_000, do: format_decimal(value / 60_000, "m")
  def format_ms(value), do: format_decimal(value / 3_600_000, "h")

  def format_decimal(value, suffix) do
    number =
      :erlang.float_to_binary(value, decimals: 1)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

    number <> suffix
  end

  def format_integer(value),
    do:
      Integer.to_string(value)
      |> String.reverse()
      |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
      |> String.reverse()

  def plural(1, noun), do: "1 #{noun}"
  def plural(value, noun), do: "#{value} #{noun}s"
  def plural(1, noun, _plural), do: "1 #{noun}"
  def plural(value, _noun, plural), do: "#{value} #{plural}"

  def optional_human(nil), do: nil
  def optional_human(value), do: human(value)

  def human(nil), do: "unrecorded"
  def human(value) when is_atom(value), do: value |> Atom.to_string() |> human()
  def human(value) when is_binary(value), do: String.replace(value, "_", " ")
  # Retained payloads carry whatever an older worker wrote. A structured value
  # where a label was expected is unreadable, not a reason to lose the page.
  def human(value) when is_map(value) or is_list(value), do: "unreadable"
  def human(value), do: to_string(value)

  def capitalize(value), do: String.capitalize(value)

  def present(nil), do: nil
  def present(value), do: bounded(to_string(value), 2_000)

  def state_tone(state)
      when state in [:blocked, "blocked", :failed, "failed", :superseded, "superseded"], do: :bad

  def state_tone(state)
      when state in [
             :complete,
             "complete",
             :settled,
             "settled",
             :delivered,
             "delivered",
             :published,
             "published",
             :ready,
             "ready",
             :active,
             "active"
           ],
      do: :good

  def state_tone(state)
      when state in [
             :waiting_for_input,
             :waiting_for_event,
             :cancelled,
             :cancel_pending,
             :pending,
             :review_pending,
             :publish_pending
           ],
      do: :warn

  def state_tone(_state), do: nil

  def segment(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  def timestamp_precise(%DateTime{} = value),
    do: Calendar.strftime(value, "%d %b %Y %H:%M:%S.%f UTC")

  def timestamp_precise(_value), do: "Not recorded"

  def error_sentence(nil), do: ""
  def error_sentence(code), do: " " <> error_label(code) <> "."

  def error_label(nil), do: nil
  def error_label(code), do: code |> human() |> capitalize() |> bounded(200)

  def live_after?(%DateTime{} = at, now), do: DateTime.compare(at, now) == :gt
  def live_after?(_at, _now), do: false

  def nonnegative_diff(%DateTime{} = right, %DateTime{} = left),
    do: max(DateTime.diff(right, left, :millisecond), 0)

  def nonnegative_diff(_right, _left), do: nil
end
