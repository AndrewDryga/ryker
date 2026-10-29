defmodule Ryker.Charts.Spec do
  @moduledoc "Five chart styles with inline data, explicit units and no executable specifications."
  alias Ryker.Maps
  alias Ryker.Reference

  @types ~w(line bar histogram heatmap scatter)
  @colors ~w(#36E6A5 #8CBFFF #E9B5FF #FFD38A #FF9C9C #94D9DC)
  @fields ~w(type title x_label y_label data)

  @doc "Build the Vega-Lite specification; user input supplies values and labels only."
  @spec build(term()) :: {:ok, map()} | {:error, {:invalid_chart, String.t(), String.t()}}
  def build(%{} = arguments) do
    with :ok <-
           check(Maps.exact_keys?(arguments, @fields), "/", "use only the required chart fields"),
         :ok <-
           check(
             arguments["type"] in @types,
             "/type",
             "choose line, bar, histogram, heatmap or scatter"
           ),
         :ok <- validate_fields(arguments, Enum.map(~w(title x_label y_label), &{&1, :label}), ""),
         :ok <- validate_rows(arguments["data"], arguments["type"]) do
      {:ok, specification(arguments)}
    end
  end

  def build(_arguments), do: check(false, "/", "must be a chart object")

  defp validate_rows(rows, type) when is_list(rows) and length(rows) in 1..500 do
    row_result =
      rows
      |> Enum.with_index()
      |> Enum.reduce_while(:ok, fn {row, index}, :ok ->
        continue_validation(validate_row(row, type, "/data/#{index}"))
      end)

    with :ok <- row_result,
         :ok <-
           check(
             Enum.all?(rows, &Map.has_key?(&1, "series")) or
               Enum.all?(rows, &(not Map.has_key?(&1, "series"))),
             "/data",
             "supply series on every row or none"
           ),
         :ok <-
           check(
             rows |> Enum.map(& &1["series"]) |> Enum.uniq() |> length() <= 6,
             "/data",
             "use at most six series"
           ),
         :ok <-
           check(
             unique_cells?(rows, type),
             "/data",
             "bar x/series pairs and heatmap x/y cells must be unique; aggregate repeated cells first"
           ) do
      check(categories_within_bounds?(rows, type), "/data", "use at most 24 categories per axis")
    end
  end

  defp validate_rows(_rows, _type), do: check(false, "/data", "must contain 1-500 observations")

  defp validate_row(%{} = row, type, path) do
    fields = row_fields(type)
    series = if type in ~w(line bar scatter), do: [{"series", :label}], else: []
    allowed = Enum.map(fields ++ series, &elem(&1, 0))
    supplied_series = if Map.has_key?(row, "series"), do: series, else: []

    with :ok <-
           check(
             Maps.only_keys?(row, allowed),
             path,
             "contains fields this chart type does not use"
           ) do
      validate_fields(row, fields ++ supplied_series, path)
    end
  end

  defp validate_row(_row, _type, path), do: check(false, path, "must be an observation object")

  defp row_fields("line"), do: [{"x", :timestamp}, {"y", :number}]
  defp row_fields("bar"), do: [{"x", :label}, {"y", :number}]
  defp row_fields("histogram"), do: [{"x", :number}]
  defp row_fields("scatter"), do: [{"x", :number}, {"y", :number}]
  defp row_fields("heatmap"), do: [{"x", :label}, {"y", :label}, {"value", :number}]

  defp validate_fields(values, fields, path) do
    Enum.reduce_while(fields, :ok, fn {field, type}, :ok ->
      {valid?, rule} = value_rule(values[field], type)
      continue_validation(check(valid?, path <> "/" <> field, rule))
    end)
  end

  defp value_rule(value, :label),
    do: {label?(value), "must be nonblank text of at most 100 characters"}

  defp value_rule(value, :number), do: {number?(value), "must be a number within +/-1e15"}

  defp value_rule(value, :timestamp),
    do: {timestamp?(value), "must be an ISO date or timestamp with a timezone"}

  defp check(true, _path, _rule), do: :ok
  defp check(false, path, rule), do: {:error, {:invalid_chart, path, rule}}
  defp continue_validation(:ok), do: {:cont, :ok}
  defp continue_validation(error), do: {:halt, error}

  defp categories_within_bounds?(rows, type) when type in ~w(bar heatmap) do
    fields = if type == "heatmap", do: ~w(x y), else: ["x"]

    Enum.all?(fields, fn field ->
      rows |> Enum.map(& &1[field]) |> Enum.uniq() |> length() <= 24
    end)
  end

  defp categories_within_bounds?(_rows, _type), do: true

  defp unique_cells?(rows, type) when type in ~w(bar heatmap) do
    fields = if type == "heatmap", do: ~w(x y), else: ~w(x series)
    cells = Enum.map(rows, &Map.take(&1, fields))
    cells == Enum.uniq(cells)
  end

  defp unique_cells?(_rows, _type), do: true

  defp label?(value), do: Reference.text?(value, 100)
  defp number?(value), do: is_number(value) and abs(value) <= 1.0e15

  defp timestamp?(value) when is_binary(value) do
    match?({:ok, _date}, Date.from_iso8601(value)) or
      match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value))
  end

  defp timestamp?(_value), do: false

  defp specification(arguments) do
    %{
      "$schema" => "https://vega.github.io/schema/vega-lite/v6.json",
      "width" => 680,
      "height" => 340,
      "padding" => 28,
      "background" => "#111315",
      "title" => %{"text" => arguments["title"], "anchor" => "start", "offset" => 24},
      "data" => %{"values" => arguments["data"]},
      "config" => theme()
    }
    |> Map.merge(chart(arguments))
  end

  defp chart(%{"type" => "line"} = arguments) do
    %{
      "mark" => %{"type" => "line", "strokeWidth" => 3, "point" => true},
      "encoding" =>
        encodings(arguments, "temporal", "quantitative")
        |> put_in(["x", "scale"], %{"type" => "utc"})
        |> series(arguments)
    }
  end

  defp chart(%{"type" => "bar"} = arguments) do
    %{
      "mark" => %{"type" => "bar", "cornerRadiusEnd" => 3},
      "encoding" =>
        encodings(arguments, "nominal", "quantitative")
        |> put_in(["x", "sort"], nil)
        |> series(arguments)
        |> grouped_bars(arguments)
    }
  end

  defp chart(%{"type" => "histogram"} = arguments) do
    %{
      "mark" => %{"type" => "bar", "binSpacing" => 2, "cornerRadiusEnd" => 2},
      "encoding" => %{
        "x" => %{
          "field" => "x",
          "type" => "quantitative",
          "title" => arguments["x_label"],
          "bin" => %{"maxbins" => 20}
        },
        "y" => %{
          "aggregate" => "count",
          "type" => "quantitative",
          "title" => arguments["y_label"]
        }
      }
    }
  end

  defp chart(%{"type" => "heatmap"} = arguments) do
    %{
      "mark" => %{"type" => "rect", "stroke" => "#111315", "strokeWidth" => 2},
      "encoding" =>
        encodings(arguments, "nominal", "nominal")
        |> put_in(["x", "sort"], nil)
        |> put_in(["y", "sort"], nil)
        |> Map.put("color", %{
          "field" => "value",
          "type" => "quantitative",
          "title" => nil,
          "scale" => %{"range" => ["#263D37", "#36E6A5"]}
        })
    }
  end

  defp chart(%{"type" => "scatter"} = arguments) do
    %{
      "mark" => %{"type" => "point", "filled" => true, "size" => 80, "opacity" => 0.85},
      "encoding" => encodings(arguments, "quantitative", "quantitative") |> series(arguments)
    }
  end

  defp encodings(arguments, x_type, y_type) do
    %{
      "x" => %{
        "field" => "x",
        "type" => x_type,
        "title" => arguments["x_label"],
        "axis" => x_axis(arguments, x_type)
      },
      "y" => %{"field" => "y", "type" => y_type, "title" => arguments["y_label"]}
    }
  end

  defp x_axis(arguments, "nominal") do
    values = arguments["data"] |> Enum.map(& &1["x"]) |> Enum.uniq()

    angle =
      cond do
        length(values) > 8 -> -90
        Enum.all?(values, &(String.length(&1) <= 12)) -> 0
        true -> -35
      end

    %{"labelAngle" => angle, "labelOverlap" => false, "grid" => false}
  end

  defp x_axis(_arguments, _type), do: %{"grid" => false, "tickCount" => 6}

  defp series(encoding, arguments) do
    if Enum.any?(arguments["data"], &is_binary(&1["series"])) do
      Map.put(encoding, "color", %{"field" => "series", "type" => "nominal", "title" => nil})
    else
      encoding
    end
  end

  defp grouped_bars(encoding, arguments) do
    if Enum.any?(arguments["data"], &is_binary(&1["series"])),
      do: Map.put(encoding, "xOffset", %{"field" => "series"}),
      else: encoding
  end

  defp theme do
    %{
      "font" => "IBM Plex Sans",
      "view" => %{"stroke" => nil},
      "title" => %{"color" => "#F2EEE5", "fontSize" => 24, "fontWeight" => 600},
      "axis" => %{
        "labelColor" => "#D6D4CE",
        "titleColor" => "#F2EEE5",
        "labelFontSize" => 13,
        "titleFontSize" => 14,
        "titleFontWeight" => 400,
        "labelPadding" => 8,
        "titlePadding" => 16,
        "gridColor" => "#303538",
        "domain" => false,
        "ticks" => false,
        "labelLimit" => 0,
        "labelOverlap" => true
      },
      "legend" => %{
        "orient" => "bottom",
        "labelColor" => "#F2EEE5",
        "labelFontSize" => 13,
        "labelLimit" => 0,
        "padding" => 12,
        "symbolSize" => 100
      },
      "range" => %{"category" => @colors},
      "mark" => %{"color" => hd(@colors)}
    }
  end
end
