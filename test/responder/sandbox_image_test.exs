defmodule Responder.SandboxImageTest do
  use ExUnit.Case, async: true

  @dockerfile Path.expand("../../.agent/Dockerfile", __DIR__)

  test "the project image inherits Coop's trusted output-contract sandbox" do
    dockerfile = File.read!(@dockerfile)

    assert dockerfile =~ "ARG COOP_BASE_IMAGE=coop-box"
    assert dockerfile =~ "FROM ${COOP_BASE_IMAGE}"
    assert dockerfile =~ "COPY --chown=node:node .tool-versions"

    refute dockerfile =~ ~r/^FROM\s+(?:debian|ubuntu|node):/m
    refute dockerfile =~ ~r/^\s*(?:USER|ENTRYPOINT|CMD)\b/m
  end
end
