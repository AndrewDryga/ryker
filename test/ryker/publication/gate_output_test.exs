defmodule Ryker.Publication.GateOutputTest do
  @moduledoc """
  Andrew, 2026-09-28: "Ryker should get full access to errors, warnings and all
  other output to work, like any llm model would, it's a sandbox!!" Coop will
  serve a review gate's complete stdout and stderr page by page; Ryker reads
  every page and keeps it as the file a fix turn is handed. Coop has not shipped
  the read yet, so an adapter without it must leave the output unread, and a
  broken read must never cost the review it follows.
  """
  use Ryker.DataCase, async: true
  alias Ryker.Artifacts
  alias Ryker.Publication.{GateOutput, Publication}

  # One page per cursor, the last with no next cursor; an error or a page of
  # any other shape where the test asks for one.
  defmodule Pages do
    def read_review_gate_output(pages, "coop-session", "op-review", cursor) do
      case Map.fetch!(pages, cursor) do
        {:error, _reason} = error -> error
        page -> {:ok, page}
      end
    end
  end

  # A reader that never says it is done.
  defmodule Endless do
    def read_review_gate_output(_client, _session, _operation, cursor),
      do: {:ok, %{"output" => "again\n", "next_cursor" => "#{cursor}+"}}
  end

  # An adapter that predates the read: Coop has not shipped it.
  defmodule Unshipped do
  end

  @review %{"operation_id" => "op-review", "session_id" => "coop-session"}

  test "a failed gate's output is read page by page, whole, and kept as the fix turn's file" do
    publication = publication()
    first = String.duplicate("compiling lib/parser.ex\n", 1_000)
    last = "FAILED test/parser_test.exs:12\n"

    pages = %{
      nil => %{"output" => first, "next_cursor" => "2"},
      "2" => %{"output" => "warning: unused variable\n", "next_cursor" => "3"},
      "3" => %{"output" => last, "next_cursor" => nil}
    }

    output = first <> "warning: unused variable\n" <> last

    assert %{"status" => "read", "bytes" => bytes, "artifact" => file} =
             GateOutput.capture(Pages, pages, publication, @review)

    assert bytes == byte_size(output)
    assert file["name"] == "gate-output.txt"
    assert {:ok, [%{"data" => ^output}]} = Artifacts.coop_inputs([file["artifact_ref"]])
    assert GateOutput.ending(%{"status" => "read", "artifact" => file}, 31) == last

    # A retried read of the same review keeps the same file.
    assert %{"artifact" => ^file} = GateOutput.capture(Pages, pages, publication, @review)
  end

  test "an output longer than the file keeps its end and says how long it was" do
    megabyte = String.duplicate("x", 1_024 * 1_024 - 1) <> "\n"

    pages =
      Map.new(0..5, fn page ->
        cursor = if page == 0, do: nil, else: "#{page}"
        next = if page == 5, do: nil, else: "#{page + 1}"
        text = if page == 5, do: megabyte <> "the failing test\n", else: megabyte
        {cursor, %{"output" => text, "next_cursor" => next}}
      end)

    assert %{"status" => "read", "bytes" => bytes, "artifact" => file} =
             GateOutput.capture(Pages, pages, publication(), @review)

    assert bytes == 6 * 1_024 * 1_024 + byte_size("the failing test\n")
    assert file["bytes"] == 4 * 1_024 * 1_024
    assert {:ok, [%{"data" => kept}]} = Artifacts.coop_inputs([file["artifact_ref"]])
    assert String.ends_with?(kept, "the failing test\n")
  end

  test "bytes a text file cannot hold are mended rather than losing the output" do
    pages = %{nil => %{"output" => "ok\0 then <<\xFF\xFE>> then end\n", "next_cursor" => nil}}

    assert %{"artifact" => file} = GateOutput.capture(Pages, pages, publication(), @review)
    assert {:ok, [%{"data" => kept}]} = Artifacts.coop_inputs([file["artifact_ref"]])
    assert String.valid?(kept)
    refute kept =~ <<0>>
    assert kept =~ "ok then <<"
    assert String.ends_with?(kept, " then end\n")
  end

  # Coop keeps the first 64 MiB of a gate that prints without end, and says so
  # on every page. That word stays with the file, so the fix turn is not told
  # a cut log is the whole run.
  test "Coop's word that it kept only part of the output stays with the file" do
    cut = "The check printed more than 64 MiB; Coop kept the first 64 MiB."

    pages = %{
      nil => %{
        "output" => "compiling\n",
        "next_cursor" => "10",
        "bytes" => 15,
        "complete" => false,
        "incomplete" => cut
      },
      "10" => %{
        "output" => "FAIL\n",
        "next_cursor" => nil,
        "bytes" => 15,
        "complete" => false,
        "incomplete" => cut
      }
    }

    assert %{"status" => "read", "bytes" => 15, "incomplete" => ^cut} =
             output = GateOutput.capture(Pages, pages, publication(), @review)

    assert {:ok, ^output} = GateOutput.prepare(output)
    assert {:error, _reason} = GateOutput.prepare(%{output | "incomplete" => " "})

    # A complete output carries no such word.
    complete = put_in(pages, [nil, "complete"], true) |> put_in(["10", "complete"], true)
    refute Map.has_key?(GateOutput.capture(Pages, complete, publication(), @review), "incomplete")
  end

  test "Coop's word that it could not keep the output is kept, never an empty file" do
    lost = %{nil => %{"lost" => "the job's log was removed before the review read it"}}

    assert GateOutput.capture(Pages, lost, publication(), @review) == %{
             "reason" => "the job's log was removed before the review read it",
             "status" => "lost"
           }

    assert GateOutput.capture(Pages, %{nil => %{"lost" => " "}}, publication(), @review) == %{
             "reason" => "Coop gave no reason.",
             "status" => "lost"
           }
  end

  # Until Coop ships the read, and whenever a read breaks, the review is stored
  # as before and the fix round tells the agent to run the gate itself.
  test "without a reader, or with one that fails, the output is simply unread" do
    assert GateOutput.capture(Unshipped, nil, publication(), @review) == nil

    for pages <- [
          %{nil => {:error, {:coop_unavailable, "worker restarting"}}},
          %{nil => %{"output" => "partial\n", "next_cursor" => "2"}, "2" => {:error, :timeout}},
          %{nil => %{"unexpected" => true}}
        ] do
      assert GateOutput.capture(Pages, pages, publication(), @review) == nil
    end

    assert GateOutput.capture(Endless, nil, publication(), @review) == nil
    assert GateOutput.ending(nil, 16_384) == nil
  end

  test "custody keeps only a read file or Coop's reason" do
    assert GateOutput.prepare(nil) == {:ok, nil}
    assert {:ok, _lost} = GateOutput.prepare(%{"reason" => "gone", "status" => "lost"})

    for invalid <- [
          %{"reason" => "", "status" => "lost"},
          %{"status" => "read", "bytes" => 1, "artifact" => %{"name" => "other.txt"}},
          %{"status" => "unknown"},
          "read"
        ] do
      assert {:error, {:invalid_publication_gate_output, _field}} = GateOutput.prepare(invalid)
    end
  end

  defp publication do
    id = Ecto.UUID.generate()
    %Publication{id: id, ref: "publication:#{id}", review_generation: 1}
  end
end
