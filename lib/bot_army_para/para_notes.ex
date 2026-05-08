defmodule BotArmyPara.ParaNotes do
  @moduledoc """
  Higher-level PARA note operations built on top of `BotArmyPara.ParaFs`.
  """

  @schema_version "1.0"
  @digest_marker "<!-- para-digest -->"

  @spec capture_append(map()) :: {:ok, map()} | {:error, String.t(), atom()}
  def capture_append(payload) when is_map(payload) do
    with :ok <- validate_schema_version(payload),
         source <- source_slug(payload),
         relative_path <- "inbox/bots/#{source}.md",
         content <- build_capture_entry(payload),
         {:ok, data} <-
           write(
             %{"relative_path" => relative_path, "content" => content, "mode" => "append"},
             payload
           ) do
      {:ok, Map.put(data, "captured_from", source)}
    end
  end

  def capture_append(_), do: {:error, "request body must be an object", :validation_error}

  @spec route_note(map()) :: {:ok, map()} | {:error, String.t(), atom()}
  def route_note(payload) when is_map(payload) do
    with :ok <- validate_schema_version(payload),
         {:ok, relative_path} <- routed_relative_path(payload),
         content <- build_routed_entry(payload),
         {:ok, data} <-
           write(
             %{"relative_path" => relative_path, "content" => content, "mode" => "append"},
             payload
           ) do
      {:ok, Map.put(data, "route", relative_path)}
    end
  end

  def route_note(_), do: {:error, "request body must be an object", :validation_error}

  @spec digest_generate(map()) :: {:ok, map()} | {:error, String.t(), atom()}
  def digest_generate(payload) when is_map(payload) do
    with :ok <- validate_schema_version(payload),
         {:ok, sources} <- read_sources(payload),
         digest <- build_digest(payload, sources),
         target <- Map.get(payload, "target_path", "inbox/review_digest.md"),
         {:ok, data} <-
           write(%{"relative_path" => target, "content" => digest, "mode" => "write"}, payload) do
      {:ok, Map.put(data, "source_count", length(sources))}
    end
  end

  def digest_generate(_), do: {:error, "request body must be an object", :validation_error}

  defp validate_schema_version(%{"schema_version" => @schema_version}), do: :ok

  defp validate_schema_version(_),
    do: {:error, ~s(schema_version must be "1.0"), :validation_error}

  defp source_slug(payload) do
    payload
    |> Map.get("source_bot", "unknown")
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unknown"
      value -> value
    end
  end

  defp iso_now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp build_capture_entry(payload) do
    summary = Map.get(payload, "summary", "(no summary)") |> to_string() |> String.trim()
    details = Map.get(payload, "details", "") |> to_string() |> String.trim()
    topic = Map.get(payload, "topic", "") |> to_string() |> String.trim()
    task = Map.get(payload, "task_id", "") |> to_string() |> String.trim()
    project = Map.get(payload, "project_ref", "") |> to_string() |> String.trim()

    refs =
      [{"topic", topic}, {"task_id", task}, {"project_ref", project}]
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)

    """
    - [#{iso_now()}] #{summary}
      #{if(details == "", do: "details: (none)", else: "details: #{details}")}
      #{if(refs == "", do: "refs: (none)", else: "refs: #{refs}")}
    """
  end

  defp routed_relative_path(payload) do
    project_ref = Map.get(payload, "project_ref", "") |> to_string() |> String.trim()
    area_ref = Map.get(payload, "area_ref", "") |> to_string() |> String.trim()
    source = source_slug(payload)

    cond do
      project_ref != "" ->
        {:ok, "projects/#{slug(project_ref)}/WEEKLY_LOG.md"}

      area_ref != "" ->
        {:ok, "areas/#{slug(area_ref)}/LOG.md"}

      true ->
        {:ok, "inbox/bots/#{source}.md"}
    end
  end

  defp build_routed_entry(payload) do
    summary = Map.get(payload, "summary", "(no summary)") |> to_string() |> String.trim()
    why = Map.get(payload, "why", "") |> to_string() |> String.trim()
    details = Map.get(payload, "details", "") |> to_string() |> String.trim()

    """
    ## #{iso_now()} - #{summary}
    #{if(why == "", do: "why: (unspecified)", else: "why: #{why}")}
    #{if(details == "", do: "", else: "\n#{details}\n")}
    """
  end

  defp read_sources(payload) do
    source_paths = Map.get(payload, "source_paths", [])

    if is_list(source_paths) do
      source_paths
      |> normalize_source_paths()
      |> collect_sources()
    else
      {:error, "source_paths must be an array", :validation_error}
    end
  end

  defp build_digest(payload, sources) do
    title = Map.get(payload, "title", "PARA Digest") |> to_string()
    generated_at = iso_now()

    body =
      sources
      |> Enum.map_join("\n\n", fn {rel, text} ->
        trimmed = text |> String.trim() |> String.slice(0, 2000)
        "### #{rel}\n\n#{if(trimmed == "", do: "(empty)", else: trimmed)}"
      end)

    """
    # #{title}
    #{@digest_marker}
    Generated at: #{generated_at}

    #{if(sources == [], do: "No source files were provided.", else: body)}
    """
  end

  defp write(base_payload, source_payload) do
    passthrough_auth =
      case Map.get(source_payload, "auth_token") do
        token when is_binary(token) and token != "" -> %{"auth_token" => token}
        _ -> %{}
      end

    BotArmyPara.ParaFs.handle_write(
      Map.merge(base_payload |> Map.put("schema_version", @schema_version), passthrough_auth)
    )
  end

  defp read_relative(relative_path) do
    root = BotArmyPara.ParaFs.default_root()
    target = Path.expand(relative_path, root)
    root_expanded = Path.expand(root)

    if String.starts_with?(target, root_expanded <> "/") or target == root_expanded do
      case File.read(target) do
        {:ok, body} -> {:ok, body}
        {:error, reason} -> {:error, "failed to read #{relative_path}: #{reason}", :io_error}
      end
    else
      {:error, "source path escapes PARA_FS_ROOT", :validation_error}
    end
  end

  defp normalize_source_paths(source_paths) do
    source_paths
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(30)
  end

  defp collect_sources(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn rel, {:ok, acc} ->
      case read_relative(rel) do
        {:ok, body} -> {:cont, {:ok, [{rel, body} | acc]}}
        {:error, message, code} -> {:halt, {:error, message, code}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      other -> other
    end
  end

  defp slug(raw) do
    raw
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\-]+/, "_")
    |> String.trim("_")
    |> case do
      "" -> "unknown"
      value -> value
    end
  end
end
