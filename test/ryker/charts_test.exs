defmodule Ryker.ChartsTest do
  use ExUnit.Case, async: false
  import Ryker.TestHelpers, only: [eventually: 1]
  alias Ryker.Charts

  setup context do
    if directory = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(directory) end)
    :ok
  end

  test "each chart preserves supplied observations and has labelled axes" do
    for {type, data} <- [
          {"line", [%{"x" => "2026-10-29", "y" => 2}]},
          {"bar", [%{"x" => "A", "y" => 2}]},
          {"histogram", [%{"x" => 2}]},
          {"heatmap", [%{"x" => "A", "y" => "B", "value" => 2}]},
          {"scatter", [%{"x" => 1.5, "y" => 2}]}
        ] do
      assert {:ok, spec} = Charts.Spec.build(arguments(type, data))
      assert spec["data"] == %{"values" => data}
      assert spec["encoding"]["x"]["title"] == "Input"
      assert spec["encoding"]["y"]["title"] == "Value (ms)"
      assert spec["config"]["font"] == "IBM Plex Sans"
    end
  end

  test "a chart cannot fetch data, inject code, or exceed its readable bounds" do
    valid = arguments("bar", [%{"x" => "A", "y" => 2}])

    for invalid <- [
          Map.put(valid, "url", "http://127.0.0.1/private"),
          Map.put(valid, "data", %{"url" => "file:///etc/passwd"}),
          Map.put(valid, "data", [%{"x" => "A", "y" => %{"expr" => "1+1"}}]),
          Map.put(valid, "data", []),
          Map.put(valid, "data", [%{"x" => "A", "y" => 1}, %{"x" => "A", "y" => 2}]),
          Map.put(valid, "data", List.duplicate(%{"x" => "A", "y" => 1}, 501)),
          Map.put(valid, "data", Enum.map(1..25, &%{"x" => "#{&1}", "y" => &1})),
          Map.put(valid, "type", "image"),
          Map.put(valid, "title", " "),
          arguments("line", [%{"x" => "2026-02-30", "y" => 1}]),
          arguments("scatter", [%{"x" => 1, "y" => 1.0e16}])
        ] do
      assert {:error, {:invalid_chart, path, rule}} = Charts.Spec.build(invalid)
      assert String.starts_with?(path, "/")
      assert is_binary(rule)
    end
  end

  test "series are compared beside each other and a timeline uses UTC" do
    data = [%{"x" => "A", "y" => 2, "series" => "First"}]
    assert {:ok, spec} = Charts.Spec.build(arguments("bar", data))
    assert spec["encoding"]["color"]["field"] == "series"
    assert spec["encoding"]["xOffset"]["field"] == "series"
    assert spec["encoding"]["x"]["axis"]["labelAngle"] == 0

    assert {:ok, spec} = Charts.Spec.build(arguments("line", [%{"x" => "2026-10-29", "y" => 2}]))
    assert spec["encoding"]["x"]["scale"] == %{"type" => "utc"}
  end

  @tag :tmp_dir
  test "concurrent requests start only one renderer and release capacity after it exits", %{
    tmp_dir: directory
  } do
    script = Path.join(directory, "renderer.py")
    started = Path.join(directory, "started")
    finish = Path.join(directory, "finish")
    image = Application.app_dir(:ryker, "priv/static/brand/avatar.png")

    File.write!(script, """
    import pathlib, sys, time
    sys.stdin.readline()
    pathlib.Path(#{Jason.encode!(started)}).touch()
    while not pathlib.Path(#{Jason.encode!(finish)}).exists():
        time.sleep(0.01)
    sys.stdout.buffer.write(pathlib.Path(#{Jason.encode!(image)}).read_bytes())
    """)

    arguments = arguments("bar", [%{"x" => "A", "y" => 1}])
    options = [python: System.find_executable("python3"), renderer: script]
    rendering = Task.async(fn -> Charts.render(arguments, options) end)
    on_exit(fn -> File.write!(finish, "") end)
    assert eventually(fn -> File.exists?(started) end)

    # A busy call must not launch even the deliberately missing executable's script.
    assert Charts.render(arguments, Keyword.put(options, :renderer, "missing")) ==
             {:error, :chart_renderer_busy}

    File.write!(finish, "")
    assert {:ok, _png} = Task.await(rendering)
    assert {:ok, _png} = Charts.render(arguments, options)
  end

  @tag :tmp_dir
  test "renderer failure and timeout never become deliverable bytes", %{tmp_dir: directory} do
    script = Path.join(directory, "renderer.py")
    python = System.find_executable("python3")
    arguments = arguments("bar", [%{"x" => "A", "y" => 2}])

    File.write!(script, "import sys\nsys.stdin.readline()\nprint('not a PNG')\n")

    assert Charts.render(arguments, python: python, renderer: script) ==
             {:error, :chart_render_failed}

    File.write!(script, "import sys,time\nsys.stdin.readline()\ntime.sleep(60)\n")

    assert Charts.render(arguments, python: python, renderer: script, timeout_ms: 100) ==
             {:error, :chart_render_timeout}

    assert Charts.render(arguments, python: Path.join(directory, "missing")) ==
             {:error, :chart_renderer_unavailable}
  end

  defp arguments(type, data),
    do: %{
      "type" => type,
      "title" => "Example",
      "x_label" => "Input",
      "y_label" => "Value (ms)",
      "data" => data
    }
end
