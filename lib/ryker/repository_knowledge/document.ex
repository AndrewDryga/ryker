defmodule Ryker.RepositoryKnowledge.Document do
  @moduledoc """
  RYKER.md as Ryker writes it: checked against the repository, then rendered
  from that check alone.

  A model's answer (`Ryker.RepositoryKnowledge.Prompt.parse/1`) is an input,
  not the document. `verify/3` keeps each path that exists in the tree at the
  commit the model read and each command written in the file it cites, and
  drops the rest; an answer with nothing left that points into the
  repository is refused. `render/3` writes the document from what was kept:
  plain relative links, which work on GitHub and never go stale, and one
  provenance line, the only place the commit appears.

  `outline/4` is the fallback when no model could finish reading the
  repository: the file list, marked as an outline, never an invented
  command. `origin/1` reads which of these, if any, a RYKER.md is, and
  `same?/2` compares two documents without their provenance lines, so a
  rewrite that says the same things proposes nothing.
  """

  @provenance ~r/^Written by Ryker from `([0-9a-f]{7,40})` on (\d{4}-\d{2}-\d{2})\.[^\n]*$/m
  @outline_note "This is only an outline from the file list"
  @old_scan_prefix "# RYKER.md\n\n> Repository knowledge generated from `"
  @vendored ~w(node_modules vendor deps _build third_party)
  @guidance_names ~w(AGENTS.md CLAUDE.md GEMINI.md)
  @build_names ~w(Makefile GNUmakefile mix.exs go.mod go.work package.json Cargo.toml pyproject.toml Gemfile Dockerfile)
  @shell_operators ["&&", "||", ";", "|", ">", "<", "`", "$("]

  @type tree :: %{String.t() => :tree | :blob}

  # -- The tree --------------------------------------------------------------------

  @doc """
  The tree as `verify/3` reads it, from GitHub's recursive tree entries: each
  path, a directory (`:tree`) or a file (`:blob`). Submodules are neither.
  """
  @spec tree([map()]) :: tree()
  def tree(entries) when is_list(entries) do
    for %{"path" => path, "type" => type} <- entries,
        is_binary(path) and type in ["tree", "blob"],
        into: %{},
        do: {path, if(type == "tree", do: :tree, else: :blob)}
  end

  @doc """
  What the prompt tells the model about the tree before it reads anything:
  the root's entries, directories first and marked with a slash, and the
  build and guidance files anywhere in it, shallowest first.
  """
  @spec outline_facts(tree()) :: %{top_level: [String.t()], key_files: [String.t()]}
  def outline_facts(tree) do
    root = Enum.reject(tree, fn {path, _kind} -> String.contains?(path, "/") end)

    {directories, files} = Enum.split_with(root, fn {_path, kind} -> kind == :tree end)

    %{
      top_level:
        Enum.map(Enum.sort(directories), fn {path, _} -> path <> "/" end) ++
          Enum.map(Enum.sort(files), fn {path, _} -> path end),
      key_files:
        tree
        |> Enum.filter(fn {path, kind} -> kind == :blob and key_file?(path) end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort_by(&{length(String.split(&1, "/")), &1})
        |> Enum.take(200)
    }
  end

  @doc """
  Whether a path is one of the files that describe how to work in a
  repository: a README or CONTRIBUTING, AGENTS.md, CLAUDE.md or GEMINI.md,
  or a build file (a Makefile, mix.exs, go.mod, package.json, Cargo.toml,
  pyproject.toml, a Gemfile, a Dockerfile and the like) anywhere outside
  vendored code, or a CI workflow. The prompt shows the model these, and a
  change to one has RYKER.md read again (`Ryker.RepositoryKnowledge.Refresh`).
  """
  @spec key_file?(String.t()) :: boolean()
  def key_file?(path) do
    segments = String.split(path, "/")
    name = List.last(segments)

    not Enum.any?(segments, &(&1 in @vendored)) and
      (String.starts_with?(String.upcase(name), "README") or
         String.starts_with?(String.upcase(name), "CONTRIBUTING") or
         name in @guidance_names or name in @build_names or
         String.starts_with?(path, ".github/workflows/"))
  end

  # -- Checking an answer --------------------------------------------------------

  @doc """
  The files `verify/3` needs the text of: each file a command cites that
  exists in the tree.
  """
  @spec cited_sources(map(), tree()) :: [String.t()]
  def cited_sources(answer, tree) do
    answer.build_test_run
    |> Enum.flat_map(fn item ->
      case located(tree, item.source_file) do
        {:ok, path, :blob} -> [path]
        _missing -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.take(40)
  end

  @doc """
  Keeps what the repository shows and drops what it does not: every path
  must exist in `tree`, every source must be a file there, and every command
  must be written in the text of the file it cites (`sources`, by path), or
  name a target, script or alias that file defines. An answer with no
  component and no command left is refused, whatever else it says.

  Returns the kept answer, with each path in its canonical form and its
  kind, and how many items were dropped.
  """
  @spec verify(map(), tree(), %{String.t() => String.t()}) ::
          {:ok, map(), non_neg_integer()} | {:error, :repository_knowledge_unusable}
  def verify(answer, tree, sources) do
    components =
      answer.components
      |> keep(&locate_item(&1, tree, :path))
      |> Enum.uniq_by(& &1.path)

    commands =
      keep(answer.build_test_run, fn item ->
        with {:ok, item} <- locate_item(item, tree, :source_file, :blob),
             true <- cited?(item.command, item.source_file, Map.get(sources, item.source_file)) do
          {:ok, %{item | command: unquoted(item.command)}}
        else
          _invented -> :error
        end
      end)
      |> Enum.uniq_by(& &1.command)

    deploy = keep(answer.deploy_release, &locate_item(&1, tree, :source_file))
    conventions = keep(answer.conventions, &locate_item(&1, tree, :source_file, :blob))
    where_to_look = keep(answer.where_to_look, &locate_item(&1, tree, :path))

    kept = %{
      answer
      | components: components,
        build_test_run: commands,
        deploy_release: deploy,
        conventions: conventions,
        where_to_look: where_to_look
    }

    dropped =
      Enum.sum_by(
        ~w(components build_test_run deploy_release conventions where_to_look)a,
        fn key ->
          length(Map.fetch!(answer, key)) - length(Map.fetch!(kept, key))
        end
      )

    if components == [] and commands == [],
      do: {:error, :repository_knowledge_unusable},
      else: {:ok, kept, dropped}
  end

  defp keep(items, check) do
    Enum.flat_map(items, fn item ->
      case check.(item) do
        {:ok, kept} -> [kept]
        _dropped -> []
      end
    end)
  end

  defp locate_item(item, tree, field, only \\ nil) do
    case located(tree, Map.fetch!(item, field)) do
      {:ok, path, kind} when is_nil(only) or kind == only ->
        {:ok, item |> Map.put(field, path) |> Map.put(:kind, kind)}

      _missing ->
        :error
    end
  end

  @doc false
  @spec located(tree(), String.t()) :: {:ok, String.t(), :tree | :blob} | :error
  def located(tree, path) when is_binary(path) do
    with {:ok, path} <- canonical(path),
         kind when kind in [:tree, :blob] <- Map.get(tree, path) do
      {:ok, path, kind}
    else
      _missing -> :error
    end
  end

  defp canonical(path) do
    path =
      path
      |> String.trim()
      |> String.trim("`")
      |> trim_leading_dot_slash()
      |> String.trim_trailing("/")

    if path != "" and not String.starts_with?(path, "/") and
         Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."])),
       do: {:ok, path},
       else: :error
  end

  defp trim_leading_dot_slash("./" <> rest), do: trim_leading_dot_slash(rest)
  defp trim_leading_dot_slash(path), do: path

  @doc """
  Whether `command` is written in `text`, the file at `path`: word for word,
  whitespace aside, or, for a single command, as a target that Makefile
  defines, a script in that package.json, or an alias in that mix.exs.
  """
  @spec cited?(String.t(), String.t(), String.t() | nil) :: boolean()
  def cited?(_command, _path, nil), do: false

  def cited?(command, path, text) do
    command = unquoted(command)
    name = Path.basename(path)

    squish(command) != "" and
      (String.contains?(squish(text), squish(command)) or
         (single?(command) and defined?(name, String.split(command), text)))
  end

  defp unquoted(command) do
    command
    |> String.trim()
    |> String.trim("`")
    |> String.replace_prefix("$ ", "")
    |> String.trim()
  end

  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp single?(command), do: not Enum.any?(@shell_operators, &String.contains?(command, &1))

  defp defined?(name, words, text) do
    cond do
      makefile?(name) -> make_defined?(words, text)
      name == "package.json" -> script_defined?(words, text)
      name == "mix.exs" -> alias_defined?(words, text)
      true -> false
    end
  end

  defp makefile?(name),
    do: name in ["Makefile", "GNUmakefile", "makefile"] or String.ends_with?(name, ".mk")

  defp make_defined?(["make" | arguments], text) do
    case make_target(arguments) do
      nil -> false
      target -> MapSet.member?(make_targets(text), target)
    end
  end

  defp make_defined?(_words, _text), do: false

  defp script_defined?([runner | arguments], text) when runner in ~w(npm yarn pnpm bun) do
    with {:ok, %{"scripts" => %{} = scripts}} <- Jason.decode(text),
         script when is_binary(script) <- script_name(runner, arguments) do
      Map.has_key?(scripts, script)
    else
      _undefined -> false
    end
  end

  defp script_defined?(_words, _text), do: false

  defp alias_defined?(["mix", task | _arguments], text) do
    escaped = Regex.escape(task)

    Regex.match?(~r/^[a-z][a-z0-9_.]*$/, task) and
      Regex.match?(~r/(?:^|[\s\[,{])(?:"#{escaped}"|#{escaped}):\s*[\["&]/m, text)
  end

  defp alias_defined?(_words, _text), do: false

  # `make -C dir` or `make -f file` runs another Makefile than the one cited.
  defp make_target([option | _rest]) when option in ["-C", "-f", "--directory", "--file"],
    do: nil

  defp make_target(["-" <> _flag | rest]), do: make_target(rest)

  defp make_target([argument | rest]) do
    if String.contains?(argument, "="), do: make_target(rest), else: argument
  end

  defp make_target([]), do: nil

  defp make_targets(text) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      cond do
        String.starts_with?(line, ".PHONY:") ->
          line |> String.replace_prefix(".PHONY:", "") |> String.split()

        Regex.match?(~r/^[^\s#=:][^#=:]*::?(?!=)/, line) ->
          line |> String.split(":", parts: 2) |> hd() |> String.split()

        true ->
          []
      end
    end)
    |> MapSet.new()
  end

  defp script_name("npm", ["run", script | _rest]), do: script
  defp script_name("npm", ["run-script", script | _rest]), do: script
  defp script_name("npm", ["test" | _rest]), do: "test"
  defp script_name("npm", ["t" | _rest]), do: "test"
  defp script_name("npm", ["start" | _rest]), do: "start"
  defp script_name(runner, ["run", script | _rest]) when runner in ~w(yarn pnpm bun), do: script

  defp script_name(runner, [script | _rest]) when runner in ~w(yarn pnpm),
    do: if(String.starts_with?(script, "-"), do: nil, else: script)

  defp script_name(_runner, _arguments), do: nil

  # -- Writing it ------------------------------------------------------------------

  @doc """
  RYKER.md from a checked answer (`verify/3`): the provenance line, then a
  section for each part the answer holds, every path a plain relative link.
  """
  @spec render(map(), String.t(), Date.t()) :: String.t()
  def render(answer, commit, %Date{} = date) do
    [
      "# RYKER.md",
      provenance(commit, date),
      section("Purpose", [sentence(answer.purpose)]),
      list(
        "Components",
        answer.components,
        &"- #{link(&1.path, &1.kind)} — #{sentence(&1.what_it_does)}"
      ),
      list(
        "Build, test and run",
        answer.build_test_run,
        &"- #{code(&1.command)} — #{sentence(&1.what_it_does)} From #{link(&1.source_file, :blob)}."
      ),
      list(
        "Deploy and release",
        answer.deploy_release,
        &"- #{sentence(&1.step)} From #{link(&1.source_file, &1.kind)}."
      ),
      list(
        "Conventions",
        answer.conventions,
        &"- #{sentence(&1.rule)} From #{link(&1.source_file, :blob)}."
      ),
      list(
        "Where to look",
        answer.where_to_look,
        &"- #{clause(&1.task)}: #{link(&1.path, &1.kind)}"
      ),
      list("Open questions", answer.open_questions, &"- #{sentence(&1)}")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  @doc """
  The fallback RYKER.md when no model could finish reading the repository:
  marked as an outline in its provenance line, and made only of what the
  file list shows, the README's own words and links to the files that
  describe the repository. It invents no command.
  """
  @spec outline(tree(), String.t() | nil, String.t(), Date.t()) :: String.t()
  def outline(tree, readme, commit, %Date{} = date) do
    facts = outline_facts(tree)

    directories =
      facts.top_level
      |> Enum.filter(&String.ends_with?(&1, "/"))
      |> Enum.reject(&(String.starts_with?(&1, ".") and &1 != ".github/"))

    guidance =
      facts.key_files
      |> Enum.reject(&String.starts_with?(&1, ".github/workflows/"))
      |> Enum.take(30)

    workflows = Enum.any?(facts.key_files, &String.starts_with?(&1, ".github/workflows/"))

    [
      "# RYKER.md",
      provenance(commit, date) <>
        " #{@outline_note}: Ryker could not finish reading the repository, and replaces it " <>
        "on its next refresh.",
      section("Purpose", [readme_purpose(readme, tree)]),
      list("Components", directories, &"- #{link(String.trim_trailing(&1, "/"), :tree)}"),
      list("Files that describe it", guidance, &"- #{link(&1, :blob)}"),
      workflows &&
        section("CI", [
          "The GitHub Actions workflows are in #{link(".github/workflows", :tree)}."
        ])
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n\n")
    |> Kernel.<>("\n")
  end

  defp readme_purpose(readme, tree) do
    readme_path =
      Enum.find(["README.md", "README.rst", "README.txt", "README"], &Map.has_key?(tree, &1))

    case readme && first_paragraph(readme) do
      nil ->
        "The README does not say what the repository is for."

      paragraph ->
        "#{paragraph} From #{link(readme_path || "README.md", :blob)}."
    end
  end

  # The first paragraph in words: not a heading, a badge, an image, markup or
  # a tagline set in bold.
  defp first_paragraph(readme) do
    readme
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(
      &(String.starts_with?(&1, ["#", "!", "[!", "<", "```", "|", ">"]) or bold?(&1))
    )
    |> Enum.find(&(length(String.split(&1)) >= 8))
    |> case do
      nil -> nil
      paragraph -> paragraph |> squish() |> String.slice(0, 600) |> String.trim_trailing(".")
    end
  end

  defp bold?(paragraph),
    do: String.starts_with?(paragraph, "**") and String.ends_with?(paragraph, "**")

  defp provenance(commit, date),
    do: "Written by Ryker from `#{String.slice(commit, 0, 7)}` on #{Date.to_iso8601(date)}."

  defp section(title, paragraphs), do: Enum.join(["## " <> title | paragraphs], "\n\n")

  defp list(_title, [], _line), do: nil
  defp list(title, items, line), do: "## #{title}\n\n" <> Enum.map_join(items, "\n", line)

  # A plain relative link: GitHub resolves it against the branch the reader
  # is on, so it never points at an old commit.
  defp link(path, kind) do
    text = if kind == :tree, do: path <> "/", else: path
    "[#{escape_link_text(text)}](#{URI.encode(text, &(URI.char_unreserved?(&1) or &1 == ?/))})"
  end

  defp escape_link_text(text), do: String.replace(text, ~r/([\[\]\\])/, "\\\\\\1")

  defp code(command) do
    if String.contains?(command, "`"), do: "`` #{command} ``", else: "`#{command}`"
  end

  defp sentence(text) do
    text = String.trim(text)
    if String.ends_with?(text, [".", "!", "?", ":"]), do: text, else: text <> "."
  end

  defp clause(text),
    do: text |> String.trim() |> String.trim_trailing(".") |> String.trim_trailing(":")

  # -- Reading one ---------------------------------------------------------------

  @doc """
  Who wrote a RYKER.md: `:model` for a document Ryker wrote from a model's
  reading, `:outline` for its fallback, `:old_scan` for the file-list
  summary setup wrote before either existed, `:person` for anything else,
  and `:none` when there is no file.
  """
  @spec origin(String.t() | nil) :: :none | :model | :outline | :old_scan | :person
  def origin(nil), do: :none

  def origin(text) when is_binary(text) do
    text = String.replace(text, "\r\n", "\n")

    case Regex.run(@provenance, text) do
      [line | _captures] ->
        if String.contains?(line, @outline_note), do: :outline, else: :model

      nil ->
        if String.starts_with?(text, @old_scan_prefix), do: :old_scan, else: :person
    end
  end

  @doc """
  Whether two documents say the same things: equal once each loses its
  provenance line, which names a commit and a date every rewrite changes.
  """
  @spec same?(String.t() | nil, String.t() | nil) :: boolean()
  def same?(nil, nil), do: true
  def same?(nil, _document), do: false
  def same?(_document, nil), do: false
  def same?(left, right), do: without_provenance(left) == without_provenance(right)

  defp without_provenance(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.replace(@provenance, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end
end
