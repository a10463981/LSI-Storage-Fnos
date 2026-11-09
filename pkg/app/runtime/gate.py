#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
预热门（preheat gate）。

存在意义：LSA 初始化要几分钟，期间 /LSI/Storage/MR/API/1.0/ 返回 400，
LSA 自带前端拿到 400 就放弃渲染 → 用户看到灰屏，以为坏了。
本服务用同一个判据探测就绪，就绪前显示进度与说明，就绪后 302 跳转到 LSA。

判据（三个互相独立的信号，用来区分三种结局）：
  ① nginx 是否监听 FRONT_PORT   → 不通 = 真启动失败
  ② root API 返回 200 还是 400  → 400 = 网关插件未就绪（不是没卡）
  ③ /dev/megaraid_sas_ioctl_node 是否存在 → 不在 = 0 控制器，界面能开但列表空

仅依赖标准库，零构建。
"""
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
import http.client
import socketserver
from urllib.parse import parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

RFS = os.environ.get("RFS", "")
RUN = os.environ.get("RUN", "/tmp")
STATE = os.environ.get("STATE", os.path.join(os.path.dirname(RUN.rstrip("/")), "state"))
SOCK_PATH = os.environ.get("SOCK_PATH", "")   # 面板入口用的 unix socket（$TRIM_APPDEST/app.sock）
PREFIX = os.environ.get("GATE_PREFIX", "/app/LSI-Storage-Fnos")  # 面板把 /app/<name> 反代到本 socket
APP_CMD = os.environ.get("APP_CMD", "")     # cmd/main 的绝对路径，用于 set-password
SETUP_MARK = os.path.join(STATE, "credential-setup-done")
SETUP_LOCK = os.path.join(STATE, "setup-in-progress")
GATE_PORT = int(os.environ.get("GATE_PORT", "2463"))
FRONT_PORT = int(os.environ.get("FRONT_PORT", "2464"))
WEB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")

LOG_PATH = os.path.join(RUN, "gate.log")
START_TS = time.time()

_lock = threading.Lock()
_cache = {"t": 0.0, "code": None, "listen": False}
HTML_CACHE = {}


_APP_PREFIX_RE = re.compile(r"^/app/[^/]+(/.*)?$")


def strip_prefix(path):
    """面板通过 /app/<name>/ 反代到本 socket，真实路径带前缀；
    直连 TCP 时没有前缀。两种都要能路由。

    除了配置里那个前缀，还兜底剥掉任意 /app/<某个名字> 前缀——
    因为应用名有可能因为安装路径不同而被算错（真实踩过：
    安装钩子在暂存目录里跑，应用名成了 LSI-Storage-Fnos-0.1.9-tpk，
    结果面板访问 /app/LSI-Storage-Fnos/ 全部 404）。多一层兜底就不会再因此挂掉。
    """
    for pre in (PREFIX, PREFIX.rstrip("/")):
        if pre and (path == pre or path.startswith(pre + "/")):
            p = path[len(pre):]
            return p or "/"
    m = _APP_PREFIX_RE.match(path)
    if m:
        return m.group(1) or "/"
    return path


def log(msg):
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%F %T"), msg))
    except Exception:
        pass


def local_ip():
    """兜底 IP：仅当请求没带 Host 头（curl --http1.0 裸请求）时使用。"""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))          # 不发包，只让内核选出口地址
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def devnode_present():
    return os.path.exists("/dev/megaraid_sas_ioctl_node")


def port_listen(port, host="127.0.0.1", timeout=0.4):
    s = socket.socket()
    s.settimeout(timeout)
    try:
        s.connect((host, port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def probe_api():
    """返回 HTTP 状态码；连接失败返回 None。"""
    try:
        c = http.client.HTTPConnection("127.0.0.1", FRONT_PORT, timeout=6)
        c.request("GET", "/LSI/Storage/MR/API/1.0/")
        r = c.getresponse()
        r.read(4096)
        c.close()
        return r.status
    except Exception:
        return None


def need_setup():
    """还没设过登录口令 -> 必须先走设置页。

    为什么不能把口令"只显示一次"：用户最容易错过那一刻，错过之后既没有口令
    也没有入口。现在改成：安装向导里填了就设好；没填则阻塞在这里让用户设。
    """
    return not os.path.exists(SETUP_MARK)


def current_account():
    """当前账号名（存在 $VAR/config.json 里）。默认 LSI-Storage-Fnos。"""
    try:
        cfg = os.path.join(os.path.dirname(STATE.rstrip("/")), "config.json")
        with open(cfg, encoding="utf-8") as f:
            return (json.load(f) or {}).get("account") or "lsiadmin"
    except Exception:
        return "lsiadmin"


def apply_password(pw, account="lsiadmin"):
    """把口令交给 cmd/main set-password（经 stdin，不进 argv、不进日志）。"""
    if not APP_CMD or not os.access(APP_CMD, os.X_OK):
        log("set-password entry missing: %r" % (APP_CMD,))
        return False, "内部错误：找不到 set-password 入口，请重装应用"
    try:
        r = subprocess.run([APP_CMD, "set-password", account],
                           input=(pw + "\n").encode("utf-8"),
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=30)
    except Exception as e:
        log("set-password spawn failed: %r" % (e,))
        return False, "写入口令失败（无法执行内部命令）"
    if r.returncode != 0:
        # 只记录退出码与 stderr，绝不记录口令本身
        log("set-password rc=%d stderr=%s" %
            (r.returncode, (r.stderr or b"").decode("utf-8", "replace")[:200]))
        return False, "写入口令失败（退出码 %d），详见应用日志" % r.returncode
    return True, ""


def lsa_pid_alive():
    p = os.path.join(RUN, "lsa.ns.pid")
    try:
        with open(p) as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return True
    except Exception:
        return False


def snapshot_state():
    """带 2 秒缓存的探测，避免浏览器轮询把 LSA 打穿。"""
    now = time.time()
    with _lock:
        if now - _cache["t"] < 2.0:
            return dict(_cache)
        listen = port_listen(FRONT_PORT)
        code = probe_api() if listen else None
        _cache.update(t=now, code=code, listen=listen)
        return dict(_cache)


def compute():
    st = snapshot_state()
    listen, code = st["listen"], st["code"]

    if not listen:
        if not lsa_pid_alive():
            phase, msg = "FAILED", "管理服务进程未运行"
        else:
            phase, msg = "STARTING", "正在启动管理服务"
    elif code is None:
        phase, msg = "STARTING", "端口已监听，等待后端响应"
    elif code in (400, 502, 503, 504):
        phase, msg = "WARMING", "LSA 正在初始化"
    elif code in (200, 301, 302, 401, 403):
        phase, msg = "READY", "已就绪"
    else:
        phase, msg = "WARMING", "等待中（HTTP %s）" % code

    return {
        "phase": phase,
        "message": msg,
        "elapsed_s": int(time.time() - START_TS),
        "http_code": code,
        "port_listen": listen,
        "has_card": devnode_present(),
        "front_port": FRONT_PORT,
        "gate_port": GATE_PORT,
        "lsa_alive": lsa_pid_alive(),
        "need_setup": need_setup(),
        "account": current_account(),
    }


def load_html(name="index.html"):
    now = time.time()
    hit = HTML_CACHE.get(name)
    if hit and now - hit[0] < 30:
        return hit[1]
    p = os.path.join(WEB, name)
    try:
        with open(p, "rb") as f:
            body = f.read()
    except Exception as e:
        log("load_html %s failed: %r" % (name, e))
        body = ("<!doctype html><meta charset=utf-8><h1>RAID 监控</h1>"
                "<p>界面文件 %s 缺失，请重新安装应用。</p>" % name).encode("utf-8")
    HTML_CACHE[name] = (now, body)
    return body


class H(BaseHTTPRequestHandler):
    server_version = "LSI-Storage-Fnos-gate/1.0"

    def log_message(self, fmt, *args):
        log("%s %s" % (self.address_string(), fmt % args))

    def base(self):
        """当前请求的挂载前缀：直连是 ""，经面板反代是 "/app/LSI-Storage-Fnos"。"""
        p = self.path.split("?", 1)[0]
        if PREFIX and (p == PREFIX or p.startswith(PREFIX + "/")):
            return PREFIX
        return ""

    def _send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        raw = self.path.split("?", 1)[0]
        # 经面板反代时 URL 是 /app/<name>，没有尾斜杠 —— 相对链接会解析错，
        # 先补一个 302 到 /app/<name>/。
        if PREFIX and raw == PREFIX:
            self._send(302, b"", extra={"Location": PREFIX + "/"})
            return
        # 任意 /app/<name> 无尾斜杠也补一个斜杠（相对链接才解析得对）
        if re.match(r"^/app/[^/]+$", raw):
            self._send(302, b"", extra={"Location": raw + "/"})
            return
        path = strip_prefix(raw)
        if path == "/":
            if need_setup():
                self._send(200, load_html("setup.html"))
            else:
                self._send(200, load_html("index.html"))
        elif path in ("/status", "/api/status"):
            self._send(200, json.dumps(compute(), ensure_ascii=False),
                       "application/json; charset=utf-8")
        elif path == "/enter":
            if need_setup():
                self._send(302, b"", extra={"Location": self.base() + "/"})
                return
            st = compute()
            if st["phase"] == "READY":
                # ★ 主机名必须取自请求的 Host 头，不能用 127.0.0.1。
                #   用户从别的电脑访问时，Location 里写 127.0.0.1 会让浏览器去
                #   用户自己的机器上找 2464，必然连不上（表现为"打开就报错/空白"）。
                #   用 Host 头则"从哪进来就回哪去"，天然支持 IP、主机名、反代域名。
                host = self.headers.get("Host", "").split(":")[0] or local_ip()
                self._send(302, b"", extra={
                    "Location": "http://%s:%d/" % (host, FRONT_PORT)})
            else:
                # 未就绪时不要吐 JSON——浏览器里看到一坨 JSON 就是"报错"。
                # 直接送回门户页，让它继续显示进度。
                self._send(302, b"", extra={"Location": self.base() + "/"})
        elif path in ("/healthz", "/ping"):
            self._send(200, "ok", "text/plain; charset=utf-8")
        else:
            self._send(404, "not found", "text/plain; charset=utf-8")

    def do_HEAD(self):
        self.do_GET()

    def do_POST(self):
        # 唯一允许的写操作：提交登录口令。只写本应用自己的状态与 chroot 内的账号，
        # 不触碰阵列、不触碰 fnOS 系统配置。
        path = strip_prefix(self.path.split("?", 1)[0])
        if path == "/setup":
            self.handle_setup()
            return
        self._send(405, "read-only", "text/plain; charset=utf-8")

    def handle_setup(self):
        # 已经设过口令就不再接受提交（防止重复 POST 静默改掉用户口令）。
        # 想让设置页重新出现：执行 cmd/reset-password，它会清掉标记。
        if not need_setup():
            self._send(409, "<!doctype html><meta charset=utf-8>"
                            "<body style=\"font-family:sans-serif;padding:40px\">"
                            "<h2>口令已设置</h2><p>如需重设，请在终端执行 "
                            "<code>/var/apps/LSI-Storage-Fnos/cmd/reset-password</code>。</p></body>",
                       )
            return
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            n = 0
        if n <= 0 or n > 4096:
            self.setup_fail("提交内容异常")
            return
        raw = self.rfile.read(n).decode("utf-8", "replace")
        form = parse_qs(raw, keep_blank_values=True)
        account = (form.get("account") or ["lsiadmin"])[0].strip()
        p1 = (form.get("p1") or [""])[0]
        p2 = (form.get("p2") or [""])[0]
        ack = (form.get("acknowledged") or [""])[0]

        if not re.match(r"^[a-z_][a-z0-9_-]{0,31}$", account):
            self.setup_fail("账号名不合法：需以小写字母或下划线开头，"
                            "只含小写字母、数字、下划线、连字符，最长 32 位")
            return

        # 校验（服务端必须独立校验一遍，不能只信前端）
        if p1 != p2:
            self.setup_fail("两次输入的口令不一致")
            return
        if len(p1) < 8:
            self.setup_fail("口令至少 8 位")
            return
        if len(p1) > 128:
            self.setup_fail("口令过长（最多 128 位）")
            return
        if "\n" in p1 or "\r" in p1:
            self.setup_fail("口令不能包含换行")
            return
        if ack not in ("on", "1", "yes", "true"):
            self.setup_fail("请先勾选「我已记下这个口令」")
            return

        # 防并发/防重复提交
        try:
            os.makedirs(STATE, exist_ok=True)
            fd = os.open(SETUP_LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
        except FileExistsError:
            self.setup_fail("上一次提交还在处理中，请稍候几秒再试")
            return
        except Exception as e:
            log("setup lock error: %r" % (e,))
            self.setup_fail("无法创建提交锁")
            return

        ok, msg = apply_password(p1, account)
        if not ok:
            try:
                os.unlink(SETUP_LOCK)
            except Exception:
                pass
            self.setup_fail(msg)
            return

        log("credential setup completed for account=%s (plaintext never logged)" % account)
        self.setup_done(account)

    def setup_done(self, account):
        """设置成功后不要立刻 303 —— LSA 首次登录要 20~40 秒，
        给一个明确的完成页，把账号名和等待预期写清楚，避免用户以为没生效而反复重试。"""
        body = """<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>凭据已设置</title>
<style>
:root{--bg:#0f1115;--card:#171a21;--fg:#e6e9ef;--dim:#8b93a1;--ok:#3fb950;--line:#252a33;--acc:#4d9fe0}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
background:var(--bg);color:var(--fg);font:15px/1.7 system-ui,-apple-system,"Segoe UI","Noto Sans CJK SC",sans-serif;padding:24px}
.card{width:min(560px,100%);background:var(--card);border:1px solid var(--line);border-radius:14px;padding:30px 28px}
h1{margin:0 0 6px;font-size:20px}
.tick{display:inline-flex;width:26px;height:26px;border-radius:50%;background:rgba(63,185,80,.15);
color:var(--ok);align-items:center;justify-content:center;margin-right:9px;font-size:16px;vertical-align:-3px}
.acct{margin:20px 0 6px;padding:14px 16px;background:#0b0d11;border:1px solid var(--line);border-radius:10px}
.acct small{display:block;color:var(--dim);font-size:12.5px;margin-bottom:4px}
.acct b{font:600 20px/1.3 ui-monospace,Menlo,Consolas,monospace;letter-spacing:.4px;color:#fff}
ul{margin:16px 0 0;padding-left:20px;color:var(--dim);font-size:13.5px}
li{margin:7px 0}
li b{color:var(--fg)}
a.btn{display:inline-block;margin-top:22px;background:var(--acc);color:#08121c;text-decoration:none;
font-weight:600;padding:11px 22px;border-radius:9px}
a.btn:hover{filter:brightness(1.08)}
</style></head><body><div class="card">
<h1><span class="tick">&#10003;</span>凭据已设置</h1>
<p style="color:var(--dim);margin:0 0 4px">账号与口令已写入运行环境，可以登录了。</p>
<div class="acct"><small>登录账号名（登录 LSA 时填这个）</small><b>__ACCOUNT__</b></div>
<ul>
  <li>LSA 首次登录<b>需要 20–40 秒</b>（本机实测约 31 秒），请耐心等待，<b>不要重复点提交</b>。</li>
  <li>如果提示 <b>Invalid Credentials</b>，先确认账号名与上面完全一致（区分大小写）。</li>
  <li>忘记口令：在 fnOS 终端执行 <code>/var/apps/LSI-Storage-Fnos/cmd/reset-password</code>，再重新打开应用。</li>
</ul>
<a class="btn" href="enter">进入 RAID 管理界面</a>
</div></body></html>""".replace("__ACCOUNT__", account)
        self._send(200, body.encode("utf-8"))

    def setup_fail(self, msg):
        # 不回显用户输入，只回显校验结论
        body = ("<!doctype html><meta charset=utf-8>"
                "<body style=\"font-family:sans-serif;background:#0f1115;color:#e6e9ef;"
                "padding:40px;text-align:center\">"
                "<h2>设置未完成</h2><p>%s</p>"
                "<p><a style=\"color:#4d9fe0\" href=\"/\">返回重试</a></p></body>") % msg
        self._send(400, body.encode("utf-8"))


def pruner():
    """日志硬上限。不依赖任何未文档化的 LSA 日志级别开关。"""
    d = os.path.join(RFS, "opt/lsi/LSIStorageAuthority/logs") if RFS else ""
    cap = 128 * 1024 * 1024
    while True:
        try:
            time.sleep(300)
            if not d or not os.path.isdir(d):
                continue
            files = []
            for n in os.listdir(d):
                if n.startswith("lsa") and n.endswith(".txt"):
                    p = os.path.join(d, n)
                    try:
                        files.append((os.path.getmtime(p), os.path.getsize(p), p))
                    except OSError:
                        pass
            files.sort()
            total = sum(f[1] for f in files)
            now = time.time()
            for mt, sz, p in list(files):
                if now - mt > 3 * 86400:
                    try:
                        os.unlink(p)
                        total -= sz
                    except OSError:
                        pass
            for mt, sz, p in files[:-1]:
                if total <= cap:
                    break
                try:
                    os.unlink(p)
                    total -= sz
                except OSError:
                    pass
            if files:
                log("prune: logs now %.1f MB" % (total / 1048576.0))
        except Exception as e:
            log("prune error: %r" % (e,))


class UnixHTTPServer(socketserver.ThreadingUnixStreamServer):
    """面板入口：fnOS 通过 /app/<name> 反代到应用的 unix socket。

    mail-archiver / rustfs 都是用这个方式被面板内嵌打开的（实测它们 target/ 下
    有一个 600 的 app.sock，且 curl --unix-socket 能拿到响应）。
    """
    daemon_threads = True
    allow_reuse_address = True

    def server_bind(self):
        try:
            os.unlink(self.server_address)
        except FileNotFoundError:
            pass
        except OSError:
            pass
        super().server_bind()

    def get_request(self):
        req, _ = super().get_request()
        return req, ("unix", 0)


def main():
    os.makedirs(RUN, exist_ok=True)
    log("gate start port=%d front=%d rfs=%s" % (GATE_PORT, FRONT_PORT, RFS))
    threading.Thread(target=pruner, daemon=True).start()

    srv = ThreadingHTTPServer(("0.0.0.0", GATE_PORT), H)
    srv.daemon_threads = True

    # 面板入口（可选）：监听 unix socket
    usrv = None
    if SOCK_PATH:
        try:
            os.makedirs(os.path.dirname(SOCK_PATH), exist_ok=True)
            usrv = UnixHTTPServer(SOCK_PATH, H)
            os.chmod(SOCK_PATH, 0o600)
            threading.Thread(target=usrv.serve_forever, kwargs={"poll_interval": 0.5},
                             daemon=True).start()
            log("unix socket listening at %s (panel entry)" % SOCK_PATH)
        except Exception as e:
            log("unix socket listen failed (%s): %r" % (SOCK_PATH, e))
            usrv = None

    def bye(signum, _frm):
        log("gate got signal %d, exiting" % signum)
        threading.Thread(target=srv.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)
    try:
        srv.serve_forever(poll_interval=0.5)
    finally:
        try:
            srv.server_close()
        except Exception:
            pass
        if usrv is not None:
            try:
                usrv.shutdown(); usrv.server_close()
            except Exception:
                pass
            try:
                if os.path.exists(SOCK_PATH):
                    os.unlink(SOCK_PATH)
            except Exception:
                pass
        log("gate stopped")


if __name__ == "__main__":
    main()
