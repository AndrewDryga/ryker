defmodule Ryker.LicensingTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)

  test "first-party Ryker work is source-available under the approved BSL terms" do
    license = read!("LICENSE")

    assert license =~ "Business Source License 1.1"
    assert license =~ "Licensor:             Andrii Dryga"
    assert license =~ "Licensed Work:        Ryker"
    assert license =~ "Additional Use Grant: None"
    assert license =~ "Change Date:          2030-09-14"
    assert license =~ "Change License:       Apache License, Version 2.0"
    assert license =~ "licensing@emisar.dev"
    assert license =~ "materials distributed with their own license notices"
    refute license =~ "MIT License"
  end

  test "public repository surfaces describe Ryker as source-available rather than MIT" do
    readme = read!("README.md")

    assert readme =~ "## License"
    assert readme =~ "source-available"
    assert readme =~ "production use requires a commercial license"
    assert readme =~ "2030-09-14"
    refute readme =~ "MIT license"

    site_files = Path.wildcard(Path.join(@repo_root, "site/**/*.html"))
    assert site_files != []

    for path <- site_files do
      page = File.read!(path)
      assert page =~ "Business Source License 1.1", "missing BSL label in #{path}"
      refute page =~ "MIT license", "stale MIT label in #{path}"
    end
  end

  test "third-party font licenses remain separate from the Ryker license" do
    for path <- [
          "brand/assets/fonts/LICENSE.txt",
          "brand/ryker/FONT-LICENSE.txt",
          "priv/static/brand/fonts/LICENSE.txt"
        ] do
      notice = read!(path)
      assert notice =~ "SIL OPEN FONT LICENSE Version 1.1"
    end
  end

  defp read!(relative_path), do: File.read!(Path.join(@repo_root, relative_path))
end
