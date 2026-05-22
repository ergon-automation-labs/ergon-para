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

  def default_root do
    System.get_env("PARA_FS_ROOT") || Path.expand("~/Documents/personal_os")
  end

  defp validate_schema_version(%{"schema_version" => @schema_version}), do: :ok

  defp validate_schema_version(_),
    do: {:error, ~s(schema_version must be "1.0"), :validation_error}

  defp validate_auth_token(payload) do
    case System.get_env("PARA_FS_WRITE_TOKEN") do
      nil ->
        :ok

      token when is_binary(token) and token != "" ->
        if payload["auth_token"] == token do
          :ok
        else
          {:error, "auth_token missing or invalid", :forbidden}
        end

      _ ->
        :ok
    end
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

  defp apply_ownership(path) do
    case ownership_ids() do
      {:ok, uid, gid} ->
        case File.chown(path, uid, gid) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
        end

      :skip ->
        :ok
    end
  end

  defp ownership_ids do
    with {uid, ""} <- Integer.parse(System.get_env("PARA_FS_OWNER_UID") || ""),
         {gid, ""} <- Integer.parse(System.get_env("PARA_FS_OWNER_GID") || "") do
      {:ok, uid, gid}
    else
      _ -> :skip
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
end
