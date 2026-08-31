defmodule Responder.Fixtures.WorkspaceCheckpoint do
  @moduledoc false

  alias Responder.CoopFleet.WorkspaceCheckpoint

  def build(attributes \\ %{}) do
    patch = Map.get(attributes, :patch, <<>>)
    task = Map.get(attributes, :task, "Status: in_progress\n")

    checkpoint_ref =
      Map.get(attributes, :checkpoint_ref, "checkpoint:" <> String.duplicate("4", 32))

    session_ref = Map.fetch!(attributes, :session_ref)
    repository_ref = Map.get(attributes, :repository_ref, "responder")
    base_revision = String.duplicate("1", 40)
    committed_revision = String.duplicate("2", 40)
    candidate_tree = digest("candidate")
    task_digest = digest(task)

    manifest = %{
      "version" => 1,
      "checkpoint_ref" => checkpoint_ref,
      "repository_ref" => repository_ref,
      "base_revision" => base_revision,
      "branch_ref" => "main",
      "committed_revision" => committed_revision,
      "candidate_tree_sha256" => candidate_tree,
      "tracked_patch" => %{
        "entry" => "workspace.patch",
        "sha256" => digest(patch),
        "byte_size" => byte_size(patch)
      },
      "untracked_files" => [],
      "task_projection" => %{
        "queue_id" => String.duplicate("5", 32),
        "task_id" => String.duplicate("6", 32),
        "id" => "remote-worker-checkpoint",
        "state" => "in_progress",
        "state_sha256" => task_digest,
        "files" => [
          %{
            "path_b64" => Base.encode64("state.md"),
            "entry" => "task/000000",
            "mode" => 0o644,
            "sha256" => task_digest,
            "byte_size" => byte_size(task)
          }
        ]
      },
      "gate_receipt" => nil
    }

    bundle =
      tar([
        {"manifest.json", Jason.encode!(manifest)},
        {"workspace.patch", patch},
        {"task/000000", task}
      ])

    checkpoint = %{
      "version" => 1,
      "checkpoint_ref" => checkpoint_ref,
      "session_ref" => session_ref,
      "placement_generation" => Map.get(attributes, :placement_generation, 1),
      "repository_ref" => repository_ref,
      "base_revision" => base_revision,
      "branch_ref" => "main",
      "committed_revision" => committed_revision,
      "candidate_tree_sha256" => candidate_tree,
      "task" => %{
        "queue_id" => String.duplicate("5", 32),
        "task_id" => String.duplicate("6", 32),
        "id" => "remote-worker-checkpoint",
        "state" => "in_progress",
        "subtasks" => [false],
        "state_sha256" => task_digest
      },
      "gate" => %{"status" => "not_run"},
      "bundle" => %{
        "media_type" => WorkspaceCheckpoint.bundle_media_type(),
        "sha256" => digest(bundle),
        "byte_size" => byte_size(bundle)
      },
      "created_at" => "2026-08-29T12:00:00Z"
    }

    {checkpoint, bundle}
  end

  defp tar(members) do
    members
    |> Enum.map(fn {name, body} -> [tar_header(name, byte_size(body)), body, padding(body)] end)
    |> then(&[&1, :binary.copy(<<0>>, 1_024)])
    |> IO.iodata_to_binary()
  end

  defp tar_header(name, size) do
    header =
      IO.iodata_to_binary([
        field(name, 100),
        octal(0o644, 8),
        octal(0, 8),
        octal(0, 8),
        octal(size, 12),
        octal(0, 12),
        "        ",
        "0",
        field("", 100),
        "ustar\0",
        "00",
        field("", 32),
        field("", 32),
        octal(0, 8),
        octal(0, 8),
        field("", 155),
        :binary.copy(<<0>>, 12)
      ])

    checksum = header |> :binary.bin_to_list() |> Enum.sum()
    checksum_field = checksum |> Integer.to_string(8) |> String.pad_leading(6, "0")
    binary_part(header, 0, 148) <> checksum_field <> <<0, 32>> <> binary_part(header, 156, 356)
  end

  defp field(value, size), do: value <> :binary.copy(<<0>>, size - byte_size(value))

  defp octal(value, size) do
    encoded = Integer.to_string(value, 8) |> String.pad_leading(size - 1, "0")
    encoded <> <<0>>
  end

  defp padding(body) do
    case rem(byte_size(body), 512) do
      0 -> <<>>
      remainder -> :binary.copy(<<0>>, 512 - remainder)
    end
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
