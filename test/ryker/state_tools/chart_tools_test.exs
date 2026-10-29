defmodule Ryker.StateTools.ChartToolsTest do
  use Ryker.DataCase, async: false
  alias Ryker.Artifacts
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: Fixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Records
  alias Ryker.StateTools.{ChartTools, SchemaCheck, Tools}
  alias Ryker.Work

  setup context do
    if directory = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(directory) end)
    :ok
  end

  @tag :tmp_dir
  test "a rendered chart is retained once and belongs only to its current turn", %{
    tmp_dir: directory
  } do
    binding = binding!()
    options = renderer!(directory)
    arguments = arguments()

    assert {:ok, result} = ChartTools.render_chart(arguments, binding, options)
    assert {:ok, ^result} = ChartTools.render_chart(arguments, binding, python: "missing")
    assert result["artifact_ref"] =~ "artifact:chart:"

    assert {:ok, [artifact]} =
             Artifacts.Outputs.fetch_many(binding.turn.id, [result["artifact_ref"]])

    assert artifact.media_type == "image/png"
    assert Artifacts.Outputs.image_matches?(artifact.media_type, artifact.data)
    assert length(Artifacts.Outputs.chart_metadata(binding.turn.id)) == 1
    other = binding!()

    assert Artifacts.Outputs.fetch_many(other.turn.id, [result["artifact_ref"]]) ==
             {:error, :work_output_artifact_not_found}

    assert Artifacts.Outputs.chart_metadata(other.turn.id) == []
  end

  @tag :tmp_dir
  test "reordering the same histogram observations reuses the identical rendered image", %{
    tmp_dir: directory
  } do
    binding = binding!()
    options = renderer!(directory, identical_image: true)

    arguments = %{
      "type" => "histogram",
      "title" => "Observed durations",
      "x_label" => "Duration (ms)",
      "y_label" => "Observations",
      "data" => [%{"x" => 1}, %{"x" => 2}]
    }

    assert {:ok, result} = ChartTools.render_chart(arguments, binding, options)

    assert {:ok, ^result} =
             ChartTools.render_chart(
               Map.update!(arguments, "data", &Enum.reverse/1),
               binding,
               options
             )

    assert length(Artifacts.Outputs.chart_metadata(binding.turn.id)) == 1
  end

  @tag :tmp_dir
  test "chart creation rechecks the lease and cannot write after acceptance", %{
    tmp_dir: directory
  } do
    binding = binding!()
    options = renderer!(directory)
    stale = put_in(binding.turn.lease_ref, "expired-lease")
    assert ChartTools.render_chart(arguments(), stale, options) == {:error, :unauthorized}
    assert Artifacts.Outputs.chart_metadata(binding.turn.id) == []

    freeze_verdict!(binding, "accept")

    assert ChartTools.render_chart(arguments(), binding, options) == {:error, :unauthorized}
    assert Artifacts.Outputs.chart_metadata(binding.turn.id) == []
  end

  @tag :tmp_dir
  test "a corrective turn may replace its rejected chart with another chart", %{
    tmp_dir: directory
  } do
    binding = binding!()

    freeze_verdict!(binding, "reject")

    assert {:ok, _result} = ChartTools.render_chart(arguments(), binding, renderer!(directory))
  end

  @tag :tmp_dir
  test "failed rendering never creates an artifact", %{tmp_dir: directory} do
    binding = binding!()

    assert ChartTools.render_chart(arguments(), binding, python: Path.join(directory, "missing")) ==
             {:error, :chart_renderer_unavailable}

    assert Artifacts.Outputs.chart_metadata(binding.turn.id) == []
  end

  test "the tool is offered only where a live image reply can be delivered" do
    binding = binding!()
    assert Enum.any?(Tools.list(binding: binding), &(&1["name"] == "render_chart"))

    for episode <- [
          %{binding.episode | execution_mode: :shadow},
          %{binding.episode | destination_transport: "github"}
        ] do
      options = [binding: %{binding | episode: episode}]
      refute Enum.any?(Tools.list(options), &(&1["name"] == "render_chart"))
      assert {:error, _reason} = Tools.call("render_chart", arguments(), options)
    end
  end

  test "the schema admits numeric measurements and refuses malformed rows with a field error" do
    assert SchemaCheck.exact_schema("render_chart", arguments(), Tools.list()) == :ok

    for value <- [1.0e16, 10_000_000_000_000_000] do
      invalid = put_in(arguments(), ["data"], [%{"x" => 1, "y" => value}])

      assert {:error, {:invalid_arguments, detail}} =
               SchemaCheck.exact_schema("render_chart", invalid, Tools.list())

      assert Enum.any?(detail.issues, &(&1.path == "/data/0/y" and &1.code == "maximum"))
    end

    assert {:error, _reason} =
             SchemaCheck.exact_schema(
               "render_chart",
               Map.put(arguments(), "url", "https://example.com"),
               Tools.list()
             )
  end

  test "domain corrections identify missing measurements, bad dates and duplicate cells" do
    binding = binding!()

    for {type, data, path, rule} <- [
          {"bar", [%{"x" => "A"}], "/data/0/y", "must be a number"},
          {"line", [%{"x" => "2026-02-30", "y" => 1}], "/data/0/x", "ISO date"},
          {"bar", [%{"x" => "A", "y" => 1}, %{"x" => "A", "y" => 2}], "/data", "must be unique"}
        ] do
      arguments = arguments() |> Map.put("type", type) |> Map.put("data", data)
      assert {:error, error} = Tools.call("render_chart", arguments, binding: binding)
      assert error =~ path
      assert error =~ rule
    end

    assert Artifacts.Outputs.chart_metadata(binding.turn.id) == []
  end

  test "worker metadata cannot impersonate a controller chart" do
    metadata = %{
      "id" => "artifact:chart:forged",
      "name" => "chart.png",
      "media_type" => "image/png",
      "bytes" => 10,
      "sha256" => String.duplicate("a", 64)
    }

    assert Artifacts.Outputs.combined_metadata(Ecto.UUID.generate(), [metadata]) ==
             {:error, {:invalid_work_output_artifacts, :reserved_ref}}
  end

  @tag :tmp_dir
  test "a full turn reuses its charts but refuses another render before starting a process", %{
    tmp_dir: directory
  } do
    binding = binding!()
    options = renderer!(directory)

    refs =
      for index <- 1..5 do
        arguments = Map.put(arguments(), "title", "Chart #{index}")

        assert {:ok, %{"artifact_ref" => ref}} =
                 ChartTools.render_chart(arguments, binding, options)

        ref
      end

    assert {:ok, %{"artifact_ref" => first}} =
             ChartTools.render_chart(Map.put(arguments(), "title", "Chart 1"), binding,
               python: "missing"
             )

    assert first == hd(refs)

    assert ChartTools.render_chart(Map.put(arguments(), "title", "Chart 6"), binding,
             python: "missing"
           ) == {:error, :chart_limit_reached}

    assert length(Artifacts.Outputs.chart_metadata(binding.turn.id)) == 5

    remote = %{
      "id" => "worker-image",
      "name" => "image.png",
      "media_type" => "image/png",
      "bytes" => 10,
      "sha256" => String.duplicate("b", 64)
    }

    assert {:ok, available} = Artifacts.Outputs.combined_metadata(binding.turn.id, [remote])
    # Availability can exceed the five selected attachments; otherwise one
    # extra worker image would make an already-rendered reply unfinishable.
    assert length(available) == 6
  end

  defp freeze_verdict!(binding, verdict) do
    candidate = "{}"
    digest = Ryker.Crypto.sha256_hex(candidate)

    Repo.update_all(Work.Turn.Query.by_id(binding.turn.id),
      set: [
        candidate: candidate,
        candidate_sha256: digest,
        candidate_attempt: 1,
        validation_intent: %{"verdict" => verdict},
        validation_intent_fingerprint: digest
      ]
    )
  end

  defp arguments,
    do: %{
      "type" => "scatter",
      "title" => "Observed values",
      "x_label" => "Input",
      "y_label" => "Duration (ms)",
      "data" => [%{"x" => 1, "y" => 2.5}]
    }

  defp renderer!(directory, options \\ []) do
    path = Path.join(directory, "renderer.py")
    # The delivery test double passes a real, already bundled image through;
    # test/charts/render_test.py exercises the actual native chart renderer.
    image = Application.app_dir(:ryker, "priv/static/brand/avatar.png")
    suffix = if Keyword.get(options, :identical_image, false), do: "", else: "+request"

    File.write!(
      path,
      "import sys\nrequest=sys.stdin.buffer.readline()\nsys.stdout.buffer.write(open(#{Jason.encode!(image)},'rb').read()#{suffix})\n"
    )

    [python: System.find_executable("python3"), renderer: path]
  end

  defp binding! do
    suffix = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               Fixtures.admit_input(%{
                 episode_id: Ecto.UUID.generate(),
                 episode_key: "charts:#{suffix}",
                 native_input_id: "source:#{suffix}",
                 turn_ref: "turn:#{suffix}"
               })
             )

    assert {:ok, _session} =
             WorkSessions.pin_episode(
               transition.episode.id,
               "test-policy",
               String.duplicate("a", 64)
             )

    assert {:ok, claim} = Work.Custody.claim_next("worker:#{suffix}", 60)

    %{
      episode: claim.episode,
      session: claim.session,
      turn: claim.turn,
      state_token: Records.token(claim.turn)
    }
  end
end
