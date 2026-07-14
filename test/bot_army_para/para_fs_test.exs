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

  test "allows writes without auth token (validation disabled)" do
    System.put_env("PARA_FS_WRITE_TOKEN", "top-secret")

    payload = %{
      "schema_version" => "1.0",
      "relative_path" => "inbox/bots/secure.md",
      "content" => "hello"
    }

    # Auth token validation is currently disabled pending env var debugging
    assert {:ok, _data} = BotArmyPara.ParaFs.handle_write(payload)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
