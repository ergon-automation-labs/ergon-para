defmodule BotArmyPara.ParaFsTest do
  use ExUnit.Case
  @moduletag :core

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "bot_army_para_test_#{System.unique_integer([:positive])}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    previous_root = System.get_env("PARA_FS_ROOT")
    previous_token = System.get_env("PARA_FS_WRITE_TOKEN")
    previous_uid = System.get_env("PARA_FS_OWNER_UID")
    previous_gid = System.get_env("PARA_FS_OWNER_GID")

    System.put_env("PARA_FS_ROOT", tmp_dir)
    System.delete_env("PARA_FS_WRITE_TOKEN")
    System.delete_env("PARA_FS_OWNER_UID")
    System.delete_env("PARA_FS_OWNER_GID")

    on_exit(fn ->
      File.rm_rf!(tmp_dir)

      restore_env("PARA_FS_ROOT", previous_root)
      restore_env("PARA_FS_WRITE_TOKEN", previous_token)
      restore_env("PARA_FS_OWNER_UID", previous_uid)
      restore_env("PARA_FS_OWNER_GID", previous_gid)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  test "writes content under allowed prefix", %{tmp_dir: tmp_dir} do
    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "inbox/bots/note.md",
      "content" => "hello"
    }

    assert {:ok, data} = BotArmyPara.ParaFs.handle_write(payload)
    assert data["bytes_written"] == 5
    assert File.read!(Path.join(tmp_dir, "inbox/bots/note.md")) == "hello"
  end

  test "rejects traversal escapes" do
    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "../etc/passwd",
      "content" => "bad"
    }

    assert {:error, _message, :validation_error} = BotArmyPara.ParaFs.handle_write(payload)
  end

  test "rejects writes without auth_token when PARA_FS_WRITE_TOKEN is configured", %{
    tmp_dir: tmp_dir
  } do
    System.put_env("PARA_FS_WRITE_TOKEN", "top-secret")

    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "inbox/bots/secure.md",
      "content" => "hello"
    }

    assert {:error, "auth_token is required when PARA_FS_WRITE_TOKEN is configured", :auth_error} =
             BotArmyPara.ParaFs.handle_write(payload)

    refute File.exists?(Path.join(tmp_dir, "inbox/bots/secure.md"))

    # With auth off (env unset), the write proceeds even with a stale
    # auth_token field left in the payload.
    System.delete_env("PARA_FS_WRITE_TOKEN")
    assert {:ok, _data} = BotArmyPara.ParaFs.handle_write(payload)
    assert File.exists?(Path.join(tmp_dir, "inbox/bots/secure.md"))
  end

  test "rejects wrong auth_token when PARA_FS_WRITE_TOKEN is configured" do
    System.put_env("PARA_FS_WRITE_TOKEN", "sekrit-token")

    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "inbox/bots/secure.md",
      "content" => "hello",
      "auth_token" => "wrong-token"
    }

    assert {:error, "invalid auth_token", :auth_error} =
             BotArmyPara.ParaFs.handle_write(payload)
  end

  test "accepts matching auth_token when PARA_FS_WRITE_TOKEN is configured", %{tmp_dir: tmp_dir} do
    System.put_env("PARA_FS_WRITE_TOKEN", "sekrit-token")

    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "inbox/bots/secure.md",
      "content" => "hello",
      "auth_token" => "sekrit-token"
    }

    assert {:ok, _data} = BotArmyPara.ParaFs.handle_write(payload)
    assert File.exists?(Path.join(tmp_dir, "inbox/bots/secure.md"))
  end

  test "empty auth_token string counts as missing when auth is configured" do
    System.put_env("PARA_FS_WRITE_TOKEN", "sekrit-token")

    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "inbox/bots/secure.md",
      "content" => "hello",
      "auth_token" => ""
    }

    assert {:error, "auth_token is required when PARA_FS_WRITE_TOKEN is configured", :auth_error} =
             BotArmyPara.ParaFs.handle_write(payload)
  end

  test "lists a directory with real files without crashing on mtime", %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, "areas/companion/observations")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "2026-08-24-angle-3.md"), "content")

    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "areas/companion/observations",
      "recursive" => false
    }

    # Regression test: File.stat/1 (no options) returns mtime as an Erlang
    # datetime tuple, not a Unix integer, which crashes
    # DateTime.from_unix!/1 in build_entry/3 on every real file. Must call
    # File.stat/2 with time: :posix.
    assert {:ok, %{"entries" => entries}} = BotArmyPara.ParaFs.handle_list(payload)
    assert [%{"name" => "2026-08-24-angle-3.md", "modified_at" => %DateTime{}}] = entries
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
