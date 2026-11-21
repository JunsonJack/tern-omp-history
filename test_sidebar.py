#!/usr/bin/env python3
"""通过隔离的 Tern 窗口验证侧边栏关闭行为。"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


_tern_shim = shutil.which("tern")
_tern_gui = Path(_tern_shim).with_name("tern.exe") if _tern_shim else None
TERN = str(_tern_gui) if _tern_gui and _tern_gui.is_file() else _tern_shim
PLUGIN_DIR = Path(__file__).resolve().parent


@unittest.skipUnless(
    TERN and os.environ.get("OMP_HISTORY_UI_TEST") == "1",
    "需要 Tern 和 OMP_HISTORY_UI_TEST=1；测试会打开隔离窗口",
)
class SidebarCloseTest(unittest.TestCase):
    """验证原生关闭按钮、顶部开关和标签关闭之间的关系。"""

    @classmethod
    def setUpClass(cls):
        """启动使用独立配置和守护进程的 Tern 窗口。"""
        cls.temp = tempfile.TemporaryDirectory(prefix="omp-history-test-", dir=tempfile.gettempdir(), ignore_cleanup_errors=True)
        root = Path(cls.temp.name)
        config = root / "config"
        workspace = root / "workspace"
        (config / "plugin-data" / "omp-history").mkdir(parents=True)
        workspace.mkdir()
        (root / "agent" / "sessions").mkdir(parents=True)
        (config / "settings.json").write_text(
            json.dumps({"tabs": "Vertical", "pane_headers": "Split", "widgets": [{"id": "cpu"}]}),
            encoding="utf-8",
        )
        (config / "plugin-data" / "omp-history" / "kv.json").write_text(
            json.dumps({"visible": False, "default_hidden_v1": True}), encoding="utf-8"
        )
        cls.env = os.environ.copy()
        cls.env.update({
            "TERN_CONFIG_DIR": str(config),
            "TERN_DAEMON_SOCKET": str(root / "daemon.sock"),
            "PI_CODING_AGENT_DIR": str(root / "agent"),
        })
        cls.control = str(root / "control.sock")
        cls.workspace = str(workspace)
        cls.window = None
        cls.addClassCleanup(cls.cleanup_window)
        subprocess.run(
            [TERN, "plugin", "link", str(PLUGIN_DIR)], cwd=workspace, env=cls.env,
            check=True, capture_output=True, text=True, encoding="utf-8", timeout=15,
        )
        cls.window = subprocess.Popen(
            [TERN, "--control", cls.control], cwd=workspace, env=cls.env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if cls.window.poll() is not None:
                raise RuntimeError("隔离 Tern 窗口提前退出")
            try:
                result = cls.ctl("tree", '[title="显示/隐藏 OMP 会话历史"]')
                if result.get("count") == 1:
                    return
            except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
                pass
            time.sleep(0.1)
        raise RuntimeError("隔离 Tern 窗口未加载历史插件")

    @classmethod
    def cleanup_window(cls):
        """关闭隔离窗口并删除临时文件。"""
        if cls.window and cls.window.poll() is None:
            try:
                cls.ctl("quit")
                cls.window.wait(timeout=10)
            except (OSError, subprocess.SubprocessError):
                cls.window.terminate()
                cls.window.wait(timeout=10)
        cls.temp.cleanup()

    @classmethod
    def ctl(cls, *args):
        """向隔离窗口发送控制命令并读取结果。"""
        result = subprocess.run(
            [TERN, "ctl", "--control", cls.control, *args], cwd=cls.workspace,
            env=cls.env, check=True, capture_output=True, text=True, encoding="utf-8", timeout=15,
        )
        return json.loads(result.stdout)

    @classmethod
    def sidebar_count(cls):
        """统计隔离会话中所有标签的历史面板。"""
        result = subprocess.run(
            [TERN, "ls", "--json"], cwd=cls.workspace, env=cls.env,
            check=True, capture_output=True, text=True, encoding="utf-8", timeout=15,
        )
        sessions = json.loads(result.stdout)["sessions"]
        return sum(
            block.get("title") == "OMP History"
            for session in sessions
            for tab in session.get("tabs", [])
            for block in tab.get("blocks", [])
        )

    def test_close_sidebar_stays_closed_and_tab_close_preserves_others(self):
        """关闭面板保持隐藏；关闭整个标签不影响其他标签。"""
        self.ctl("plugins", "run", "plugin.omp-history.toggle")
        self.ctl("tab", "new")
        self.ctl("wait", "1500")
        self.assertEqual(self.sidebar_count(), 2)

        self.ctl("tab", "close")
        self.ctl("wait", "1500")
        self.assertEqual(self.sidebar_count(), 1)

        self.ctl("tab", "new")
        self.ctl("wait", "1500")
        self.assertEqual(self.sidebar_count(), 2)
        self.ctl("click", 'header[title="OMP History"] .tn-close')
        self.ctl("wait", "2300")
        self.assertEqual(self.sidebar_count(), 0)

        self.ctl("click", '[title="显示/隐藏 OMP 会话历史"]')
        self.ctl("wait", "300")
        self.assertEqual(self.sidebar_count(), 1)


@unittest.skipUnless(
    TERN and os.environ.get("OMP_HISTORY_UI_TEST") == "1",
    "需要 Tern 和 OMP_HISTORY_UI_TEST=1；测试会打开隔离窗口",
)
class GroupCollapseTest(unittest.TestCase):
    """验证按项目分组的折叠行为。复用 SidebarCloseTest 的隔离窗口引导。

    不继承 SidebarCloseTest：它自带的 test_close_* 在本机环境因
    `tern ls --json` 缺 daemon.sock 必然报错，还会把侧边栏留在关闭态。"""

    ctl = SidebarCloseTest.__dict__["ctl"]
    cleanup_window = SidebarCloseTest.__dict__["cleanup_window"]

    @classmethod
    def setUpClass(cls):
        # 复用 SidebarCloseTest 的隔离窗口引导：取出底层函数以 cls=本类调用。
        SidebarCloseTest.__dict__["setUpClass"].__func__(cls)
        sessions_dir = Path(cls.temp.name) / "agent" / "sessions"
        for index, project in enumerate(("proj-alpha", "proj-beta")):
            project_dir = Path(cls.temp.name) / "workspace" / project
            project_dir.mkdir(exist_ok=True)
            session_dir = sessions_dir / f"sess-{index:02d}"
            session_dir.mkdir(exist_ok=True)
            (session_dir / "conv.jsonl").write_text(
                "\n".join([
                    json.dumps({"type": "title", "title": f"{project} 会话"}),
                    json.dumps({"type": "session", "id": f"id-{index:02d}" * 4, "cwd": str(project_dir)}),
                ]) + "\n",
                encoding="utf-8",
            )
        # 索引冷启动要拉起 python 子进程，首次渲染可能十几秒；轮询等组头出现。
        cls.ctl("plugins", "run", "plugin.omp-history.toggle")
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            if cls.ctl("tree", ".omp-history-group").get("count", 0) >= 2:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("分组头未在 40s 内渲染")

    def group_count(self):
        return self.ctl("tree", ".omp-history-group").get("count", 0)

    def card_count(self):
        return self.ctl("tree", ".omp-history-card").get("count", 0)

    def test_group_headers_render_and_collapse(self):
        """分组模式下出现组头；点击组头折叠后卡片数减少，再点恢复。"""
        self.assertGreaterEqual(self.group_count(), 2, "应渲染出至少两个项目组头")
        before = self.card_count()
        self.assertGreaterEqual(before, 2, "折叠前应有两个会话卡")

        self.ctl("click", '.omp-history-group[title*="proj-alpha"]')
        self.ctl("wait", "1000")
        self.assertEqual(self.group_count(), 2, "折叠后组头仍应保留（重新展开入口）")
        after = self.card_count()
        self.assertLess(after, before, "折叠后可见会话卡应减少")
        kv = (Path(self.temp.name) / "config" / "plugin-data" / "omp-history" / "kv.json")
        if kv.exists():
            self.assertIn("proj-alpha", kv.read_text(encoding="utf-8"))

        self.ctl("click", '.omp-history-group[title*="proj-alpha"]')
        self.ctl("wait", "1000")
        self.assertEqual(self.card_count(), before, "再次点击组头应重新展开")


@unittest.skipUnless(
    TERN and os.environ.get("OMP_HISTORY_UI_TEST") == "1",
    "需要 Tern 和 OMP_HISTORY_UI_TEST=1；测试会打开隔离窗口",
)
class ArchiveTest(unittest.TestCase):
    """验证归档/恢复/归档视图。复用 SidebarCloseTest 的隔离窗口引导。

    与 GroupCollapseTest 同理不继承：基类的 test_close_* 依赖
    `tern ls --json` 在本机隔离环境必然失败。"""

    ctl = SidebarCloseTest.__dict__["ctl"]
    cleanup_window = SidebarCloseTest.__dict__["cleanup_window"]

    @classmethod
    def setUpClass(cls):
        # 复用 SidebarCloseTest 的隔离窗口引导：取出底层函数以 cls=本类调用。
        SidebarCloseTest.__dict__["setUpClass"].__func__(cls)
        sessions_dir = Path(cls.temp.name) / "agent" / "sessions"
        project_dir = Path(cls.temp.name) / "workspace" / "proj-alpha"
        project_dir.mkdir(exist_ok=True)
        session_dir = sessions_dir / "sess-00"
        session_dir.mkdir()
        (session_dir / "conv.jsonl").write_text(
            "\n".join([
                json.dumps({"type": "title", "title": "待归档会话"}),
                json.dumps({"type": "session", "id": "aaaa1111aaaa1111", "cwd": str(project_dir)}),
            ]) + "\n",
            encoding="utf-8",
        )
        cls.ctl("plugins", "run", "plugin.omp-history.toggle")
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            if cls.card_count() >= 1:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("会话卡未在 40s 内渲染")

    @classmethod
    def card_count(cls):
        return cls.ctl("tree", ".omp-history-card").get("count", 0)

    @classmethod
    def kv_path(cls):
        return Path(cls.temp.name) / "config" / "plugin-data" / "omp-history" / "kv.json"

    def test_archive_unarchive_and_view(self):
        """点归档按钮移卡进归档视图；恢复按钮移回主列表；kv 持久化。"""
        before = self.card_count()
        self.assertEqual(before, 1, "主列表应有 1 张会话卡")

        # 归档：卡片从主列表消失，id 写进 kv。
        self.ctl("click", ".omp-history-card-action")
        self.ctl("wait", "1000")
        self.assertEqual(self.card_count(), 0, "归档后主列表应为空")
        self.assertIn("aaaa1111", self.kv_path().read_text(encoding="utf-8"))

        # 归档视图：出现返回按钮、卡片带项目名徽标、恢复按钮。
        self.ctl("click", '[title="查看已归档会话"]')
        self.ctl("wait", "1000")
        self.assertEqual(self.card_count(), 1, "归档视图应有 1 张卡")
        self.assertEqual(self.ctl("tree", ".omp-history-archived-badge").get("count"), 1, "归档卡应带项目名徽标")

        # 恢复：回到主列表，kv 清空。
        self.ctl("click", ".omp-history-card-action")
        self.ctl("wait", "1000")
        self.assertEqual(self.card_count(), 0, "恢复后归档视图应为空")
        self.assertEqual(self.ctl("tree", '[title="查看已归档会话"]').get("count"), 0, "归档视图下应显示返回按钮而非归档入口")

        self.ctl("click", '[title="回到会话列表"]')
        self.ctl("wait", "1000")
        self.assertEqual(self.card_count(), before, "恢复后主列表应回到原有卡片数")
        self.assertNotIn("aaaa1111", self.kv_path().read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
