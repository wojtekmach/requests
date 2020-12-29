defmodule RequestsTest do
  use ExUnit.Case, async: true

  test "it works" do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"

    Bypass.expect(bypass, "GET", "/200", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    Bypass.expect(bypass, "GET", "/404", fn conn ->
      Plug.Conn.send_resp(conn, 404, "not found")
    end)

    assert Requests.get!(base_url <> "/200").status == 200
    assert Requests.get!(base_url <> "/200", headers: [{"user-agent", "requests"}]).status == 200
    assert Requests.get!(base_url <> "/200", headers: [user_agent: "requests"]).status == 200
    assert Requests.get!(base_url <> "/404").status == 404

    :ok = Bypass.down(bypass)

    assert_raise RuntimeError, ~r/:failed_connect/, fn ->
      Requests.get!(base_url <> "/200")
    end
  end
end
