defmodule Ryker.StateTools.BrowserTools do
  @moduledoc "The bounded report contract for a browser journey in the existing task sandbox."
  alias Ryker.JSONSchema

  def tool do
    %{
      "name" => "record_browser_test",
      "description" =>
        "Save the actual results of a bounded headless Playwright journey in this task's Coop environment. Reuse repository browser tests and setup instructions. Use a fresh browser context, never host cookies or production credentials; stay within existing network grants. Close the browser and stop servers you started in finally. Report failed app startup, missing browser or unreachable page as blocked, not passed. revision is the git commit and working tree tested (reported by you, not host-attested); dirty marks uncommitted changes. observed_at is the actual measurement time. Each case names steps, viewport and expected/observed behavior. A screenshot alone is not a passing test. Save only selected PNG/JPEG/WebP/GIF screenshots in the exact coop-output directory (five images, 8MiB total). screenshot is its exact filename or null; screenshot_sha256 is the SHA-256 of those captured bytes, or null without a screenshot. Include filenames in final outcome.artifact_refs. Do not create a report before running the check; this tool records evidence, it does not run a browser.",
      "inputSchema" =>
        JSONSchema.object(%{
          "title" => JSONSchema.text(160),
          "observed_at" => %{"type" => "string", "format" => "date-time"},
          "revision" =>
            JSONSchema.object(%{
              "commit" => sha(),
              "tree" => sha(),
              "dirty" => %{"type" => "boolean"}
            }),
          "cases" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 8,
            "items" =>
              JSONSchema.object(%{
                "name" => JSONSchema.text(160),
                "status" => %{"type" => "string", "enum" => ~w(passed failed blocked untested)},
                "steps" => %{
                  "type" => "array",
                  "minItems" => 1,
                  "maxItems" => 12,
                  "items" => JSONSchema.text(300)
                },
                "expected" => JSONSchema.text(1000),
                "observed" => JSONSchema.text(2000),
                "viewport" =>
                  JSONSchema.object(%{"width" => dimension(), "height" => dimension()}),
                "screenshot" => JSONSchema.nullable(JSONSchema.text(255)),
                "screenshot_sha256" =>
                  JSONSchema.nullable(%{"type" => "string", "pattern" => "^[0-9a-f]{64}$"})
              })
          }
        })
    }
  end

  defp dimension, do: %{"type" => "integer", "minimum" => 1, "maximum" => 4096}
  defp sha, do: %{"type" => "string", "pattern" => "^([0-9a-f]{40}|[0-9a-f]{64})$"}
end
