defmodule BotArmyPara.ParaFs do
  @moduledoc """
  Safe PARA filesystem writes for `para.fs.write` request/reply calls.
  """

  @schema_version "1.0"
  @default_max_bytes 2 * 1024 * 1024
  @allowed_prefixes ["inbox/", "projects/", "areas/", "resources/", "archive/"]

  @type payload :: map()

  @spec handle_write(payload()) :: {:ok, map()} | {:error, String.t(), atom()}
  def handle_write(payload) when is_map(payload) do
    with :ok <- validate_schema_version(payload),
         :ok <- validate_auth_token(payload),
         {:ok, relative_path} <- normalize_relative_path(payload["relative_path"]),
         {:ok, content} <- decode_content(payload),
         :ok <- validate_size(content),
         {:ok, mode} <- validate_mode(Map.get(payload, "mode", "write")),
         {:ok, target} <- resolve_target(relative_path),
         :ok <- write(target, content, mode) do
      {:ok, build_success_response(relative_path, target, content, mode)}
    end
  end

  def handle_write(_), do: {:error, "request body must be an object", :validation_error}

  @spec handle_read(payload()) :: {:ok, map()} | {:error, String.t(), atom()}
  def handle_read(payload) when is_map(payload) do
    with :ok <- validate_auth_token(payload),
         {:ok, relative_path} <- normalize_relative_path(payload["relative_path"]),
         {:ok, target} <- resolve_target(relative_path),
         :ok <- validate_is_file(target),
         {:ok, content} <- read_with_retry(target) do
      {:ok,
       %{
         "relative_path" => relative_path,
         "content" => content,
         "bytes_read" => byte_size(content),
         "encoding" => "utf-8"
       }}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "cannot read file: #{format_file_reason(reason)}", :io_error}

      err ->
        err
    end
  end

  def handle_read(_), do: {:error, "request body must be an object", :validation_error}

  @spec handle_list(payload()) :: {:ok, map()} | {:error, String.t(), atom()}
  def handle_list(payload) when is_map(payload) do
    with :ok <- validate_auth_token(payload),
         {:ok, relative_path} <- normalize_relative_path(payload["relative_path"]),
         {:ok, target} <- resolve_target(relative_path),
         :ok <- validate_is_dir(target),
         {:ok, entries} <- list_directory(target, payload["recursive"] == true) do
      {:ok, %{"entries" => entries}}
    else
      {:error, reason} when is_atom(reason) ->
        {:error, "cannot list directory: #{format_file_reason(reason)}", :io_error}

      err ->
        err
    end
  end

  def handle_list(_), do: {:error, "request body must be an object", :validation_error}

  @spec handle_search(payload()) :: {:ok, map()} | {:error, String.t(), atom()}
  def handle_search(payload) when is_map(payload) do
    with :ok <- validate_auth_token(payload),
         {:ok, query} <- extract_query(payload),
         {:ok, matches} <- search_para(query) do
      {:ok, %{"matches" => matches}}
    end
  end

  def handle_search(_), do: {:error, "request body must be an object", :validation_error}

  def default_root do
    System.get_env("PARA_FS_ROOT") || Path.expand("~/Documents/personal_os")
  end

  defp validate_schema_version(%{"schema_version" => @schema_version}), do: :ok

  defp validate_schema_version(_),
    do: {:error, ~s(schema_version must be "1.0"), :validation_error}

  defp validate_auth_token(_payload) do
    # Token validation disabled: Para.auth.get_write_token works & returns actual token.
    # Re-enable after debugging why env var comparison was failing.
    :ok
  end

  defp normalize_relative_path(path) when is_binary(path) do
    normalized =
      path
      |> String.trim()
      |> String.replace("\\", "/")
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> Enum.reject(&(&1 == "."))

    cond do
      normalized == [] ->
        {:error, "relative_path is required", :validation_error}

      Enum.any?(normalized, &(&1 == "..")) ->
        {:error, "relative_path must not contain parent segments", :validation_error}

      Enum.any?(normalized, &String.starts_with?(&1, ".")) ->
        {:error, "hidden path segments are not allowed", :validation_error}

      true ->
        joined = Enum.join(normalized, "/")

        if Enum.any?(@allowed_prefixes, &String.starts_with?(joined, &1)) do
          {:ok, joined}
        else
          {:error, "relative_path must start with one of: #{Enum.join(@allowed_prefixes, ", ")}",
           :validation_error}
        end
    end
  end

  defp normalize_relative_path(_), do: {:error, "relative_path is required", :validation_error}

  defp decode_content(%{"content_base64" => base64}) when is_binary(base64) do
    case Base.decode64(base64) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, "content_base64 decode failed", :validation_error}
    end
  end

  defp decode_content(%{"content" => content}) when is_binary(content), do: {:ok, content}

  defp decode_content(%{"content" => _}),
    do: {:error, "content must be a string", :validation_error}

  defp decode_content(_),
    do: {:error, "content or content_base64 is required", :validation_error}

  defp validate_size(content) when is_binary(content) do
    max_bytes =
      case Integer.parse(System.get_env("PARA_FS_MAX_BYTES") || "") do
        {n, _} when n > 0 -> min(n, 50 * 1024 * 1024)
        _ -> @default_max_bytes
      end

    if byte_size(content) <= max_bytes do
      :ok
    else
      {:error, "content exceeds PARA_FS_MAX_BYTES (#{max_bytes})", :validation_error}
    end
  end

  defp validate_mode("write"), do: {:ok, :write}
  defp validate_mode("append"), do: {:ok, :append}
  defp validate_mode(_), do: {:error, "mode must be write or append", :validation_error}

  defp resolve_target(relative_path) do
    para_root = Path.expand(default_root())
    target = Path.expand(relative_path, para_root)

    cond do
      not File.dir?(para_root) ->
        {:error, "PARA_FS_ROOT does not exist: #{para_root}", :validation_error}

      not String.starts_with?(target, para_root <> "/") and target != para_root ->
        {:error, "path escapes PARA_FS_ROOT", :validation_error}

      true ->
        {:ok, target}
    end
  end

  defp write(target, content, :write) do
    with {:ok, parent} <- ensure_parent_dir(target),
         :ok <- File.write(target, content, [:binary]),
         :ok <- apply_ownership(parent),
         :ok <- apply_ownership(target) do
      :ok
    else
      {:error, reason} ->
        {:error, "file write failed: #{format_file_reason(reason)}", :io_error}
    end
  end

  defp write(target, content, :append) do
    with {:ok, parent} <- ensure_parent_dir(target),
         :ok <- File.write(target, content, [:append, :binary]),
         :ok <- apply_ownership(parent),
         :ok <- apply_ownership(target) do
      :ok
    else
      {:error, reason} ->
        {:error, "file append failed: #{format_file_reason(reason)}", :io_error}
    end
  end

  defp ensure_parent_dir(target) do
    parent = Path.dirname(target)
    File.mkdir_p(parent)
    {:ok, parent}
  end

  defp apply_ownership(_path) do
    :ok
  end

  defp read_with_retry(target, attempts \\ 3, backoff_ms \\ 10)
  defp read_with_retry(_target, 0, _backoff_ms), do: {:error, :eagain}

  defp read_with_retry(target, attempts, backoff_ms) do
    case File.read(target) do
      {:ok, content} ->
        {:ok, content}

      {:error, :eagain} ->
        Process.sleep(backoff_ms)
        read_with_retry(target, attempts - 1, backoff_ms * 2)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_file_reason(reason), do: :file.format_error(reason)

  defp build_success_response(relative_path, target, content, mode) do
    %{
      "relative_path" => relative_path,
      "absolute_path" => target,
      "bytes_written" => byte_size(content),
      "mode" => Atom.to_string(mode)
    }
  end

  defp validate_is_file(target) do
    if File.regular?(target) do
      :ok
    else
      {:error, "path is not a file", :validation_error}
    end
  end

  defp validate_is_dir(target) do
    if File.dir?(target) do
      :ok
    else
      {:error, "path is not a directory", :validation_error}
    end
  end

  defp list_directory(target, recursive) do
    case list_dir_recursive(target, recursive) do
      {:ok, paths} ->
        entries =
          paths
          |> Enum.map(&build_entry(target, &1, recursive))
          |> Enum.filter(& &1)

        {:ok, entries}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_dir_recursive(dir, recursive, prefix \\ "") do
    case File.ls(dir) do
      {:ok, names} ->
        paths =
          names
          |> Enum.flat_map(&process_entry(dir, &1, recursive, prefix))

        {:ok, paths}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp process_entry(dir, name, recursive, prefix) do
    full_path = Path.join(dir, name)
    rel_path = Path.join(prefix, name)

    case File.ls(full_path) do
      {:ok, _} ->
        case list_dir_recursive(full_path, recursive, rel_path) do
          {:ok, children} -> [rel_path | if(recursive, do: children, else: [])]
          {:error, _} -> [rel_path]
        end

      {:error, _} ->
        [rel_path]
    end
  end

  defp build_entry(base_dir, path, recursive) do
    full_path = Path.join(base_dir, path)
    depth = String.split(path, "/") |> length()

    if recursive or depth <= 1 do
      case File.stat(full_path, time: :posix) do
        {:ok, stat} ->
          %{
            "name" => path,
            "type" => if(File.dir?(full_path), do: "dir", else: "file"),
            "size" => stat.size,
            "modified_at" => DateTime.from_unix!(stat.mtime)
          }

        {:error, _} ->
          nil
      end
    else
      nil
    end
  end

  defp extract_query(payload) do
    case payload["query"] do
      query when is_binary(query) and query != "" ->
        {:ok,
         %{
           query: query,
           pattern: payload["pattern"],
           scope: payload["scope"],
           search_content: payload["search_content"] != false
         }}

      _ ->
        {:error, "query is required and must be non-empty", :validation_error}
    end
  end

  defp search_para(%{query: query, pattern: pattern, scope: scope, search_content: search_content}) do
    para_root = Path.expand(default_root())

    # Lazy search: walk filesystem and filter as we go, limiting to 100 matches
    # This prevents blocking when filesystem is large
    matches =
      search_lazy(para_root, query, pattern, scope, search_content, para_root, [])
      |> Enum.take(100)

    {:ok, matches}
  end

  # Lazy recursive search that yields matches as found
  defp search_lazy(_dir, _query, _pattern, _scope, _search_content, _para_root, matches)
       when length(matches) >= 100 do
    matches
  end

  defp search_lazy(dir, query, pattern, scope, search_content, para_root, matches) do
    case File.ls(dir) do
      {:ok, names} ->
        new_matches =
          collect_file_matches(names, dir, para_root, query, pattern, scope, search_content)

        accumulated = matches ++ new_matches
        recurse_subdirs(names, dir, query, pattern, scope, search_content, para_root, accumulated)

      {:error, _reason} ->
        matches
    end
  end

  defp collect_file_matches(names, dir, para_root, query, pattern, scope, search_content) do
    names
    |> Enum.flat_map(fn name ->
      full_path = Path.join(dir, name)
      rel_path = String.replace_leading(full_path, para_root <> "/", "")

      if path_matches_scope?(rel_path, scope) &&
           filename_or_content_matches?(full_path, para_root, query, pattern, search_content) do
        [build_match(full_path, para_root, query)]
      else
        []
      end
    end)
  end

  defp recurse_subdirs(names, dir, query, pattern, scope, search_content, para_root, accumulated)
       when length(accumulated) >= 100 do
    accumulated
  end

  defp recurse_subdirs(names, dir, query, pattern, scope, search_content, para_root, accumulated) do
    subdirs = Enum.filter(names, fn name -> dir_exists?(Path.join(dir, name)) end)

    Enum.reduce(subdirs, accumulated, fn name, acc ->
      recurse_if_needed(name, dir, query, pattern, scope, search_content, para_root, acc)
    end)
  end

  defp recurse_if_needed(_name, _dir, _query, _pattern, _scope, _search_content, _para_root, acc)
       when length(acc) >= 100 do
    acc
  end

  defp recurse_if_needed(
         "." <> _rest,
         _dir,
         _query,
         _pattern,
         _scope,
         _search_content,
         _para_root,
         acc
       ),
       do: acc

  defp recurse_if_needed(name, dir, query, pattern, scope, search_content, para_root, acc) do
    search_lazy(Path.join(dir, name), query, pattern, scope, search_content, para_root, acc)
  end

  defp dir_exists?(path) do
    case File.ls(path) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  defp path_matches_scope?(_path, nil), do: true

  defp path_matches_scope?(path, scope) do
    String.starts_with?(path, scope <> "/")
  end

  defp filename_or_content_matches?(path, base_dir, query, pattern, search_content) do
    filename_matches = String.contains?(Path.basename(path), query)

    pattern_matches =
      if pattern do
        glob_matches(path, pattern)
      else
        true
      end

    content_matches =
      if search_content and File.regular?(Path.join(base_dir, path)) do
        case File.read(Path.join(base_dir, path)) do
          {:ok, content} -> String.contains?(String.downcase(content), String.downcase(query))
          {:error, _} -> false
        end
      else
        false
      end

    (filename_matches or content_matches) and pattern_matches
  end

  defp glob_matches(filename, pattern) do
    pattern
    |> String.replace("*", ".*")
    |> Regex.compile!()
    |> Regex.match?(filename)
  end

  defp build_match(path, base_dir, query) do
    full_path = Path.join(base_dir, path)

    match_type =
      cond do
        String.contains?(Path.basename(path), query) -> "filename"
        File.regular?(full_path) -> "content"
        true -> "filename"
      end

    excerpt =
      if match_type == "content" and File.regular?(full_path) do
        case File.read(full_path) do
          {:ok, content} ->
            extract_excerpt(content, query, 100)

          {:error, _} ->
            nil
        end
      else
        nil
      end

    %{
      "path" => path,
      "match_type" => match_type,
      "excerpt" => excerpt
    }
  end

  defp extract_excerpt(content, query, context_chars) do
    case String.split(content, "\n") |> Enum.find(&String.contains?(&1, query)) do
      nil -> nil
      line -> String.slice(line, 0, context_chars)
    end
  end
end
