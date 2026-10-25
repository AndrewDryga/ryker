defmodule Ryker.Memories.ForgettingConfirmationTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.MemoryConfirmations
  alias Ryker.Inspectors
  alias Ryker.Memories

  # Confirmation used only the ref, so a later review edit could silently
  # replace the words being erased. All entry points require the saved content.
  for surface <- [:console, :message, :home] do
    test "#{surface} refuses unconfirmed content without dismissing its review" do
      context = MemoryConfirmations.current!()

      for fingerprint <- [
            nil,
            "",
            "invalid",
            String.duplicate("A", 64),
            String.duplicate("0", 64)
          ] do
        result = forget(context, unquote(surface), fingerprint)
        memory = MemoryConfirmations.fetch!(context)

        assert memory.status == :active
        assert memory.payload == context.memory.payload

        assert Enum.any?(
                 Inspectors.memory_reviews(context.workspace_ref),
                 &(&1["review_ref"] == context.review_ref)
               )

        assert result == {:error, :confirmation_stale}
      end
    end

    test "#{surface} confirmation survives verification metadata and safely retries the same Forget" do
      context = MemoryConfirmations.current!()
      fingerprint = context.memory.payload_fingerprint

      assert {:ok, _review} =
               Memories.resolve_review(
                 context.review_ref,
                 :keep,
                 "slack:user:U123",
                 context.workspace_ref
               )

      assert {:ok, forgotten} = forget(context, unquote(surface), fingerprint)
      assert forgotten.status == :deleted
      assert forgotten.payload == %{"forgotten_payload_sha256" => fingerprint}
      assert forget(context, unquote(surface), fingerprint) == {:ok, forgotten}

      assert forget(context, unquote(surface), forgotten.payload_fingerprint) ==
               {:error, :confirmation_stale}

      assert MemoryConfirmations.fetch!(context) == forgotten
    end
  end

  defp forget(context, :console, fingerprint),
    do: Memories.forget(context.memory.ref, fingerprint)

  defp forget(context, :message, fingerprint) do
    Memories.forget_in_conversation(
      context.memory.ref,
      fingerprint,
      "slack:user:U123",
      context.workspace_ref,
      context.source.conversation_ref
    )
  end

  defp forget(context, :home, fingerprint) do
    Memories.forget_home(
      context.memory.ref,
      fingerprint,
      "slack:user:U123",
      context.workspace_ref
    )
  end
end
