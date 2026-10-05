defmodule Ryker.Fixtures.TaskOffer do
  @moduledoc """
  A task offer's payload in the one shape Ryker accepts: what a test names,
  and for the rest what the task tool would have written. Offers once came in
  three shapes; only the newest is accepted since 2026-10-05.

  Each task gets an instruction of its own unless the test names one, since a
  new offer for the same instruction and repository replaces the open one.
  """

  @spec payload(map()) :: map()
  def payload(fields \\ %{}) do
    payload =
      Map.merge(
        %{
          "authority_limits" => ["Change only what the task asks for."],
          "kind" => "engineering",
          "prompt" => "Make the requested repository change.",
          "repository" => "ryker",
          "repository_source" => nil,
          "source_refs" => [],
          "success_checks" => ["The focused tests pass."],
          "title" => "Implement the change"
        },
        fields
      )

    Map.put_new_lazy(payload, "instruction_ref", fn -> instruction_ref(payload) end)
  end

  defp instruction_ref(payload) do
    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(Map.take(payload, ~w(prompt repository title)))
      )
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "input:task-offer:" <> digest
  end
end
