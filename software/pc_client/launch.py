"""Windows entry point for the existing FPGA MJPEG web receiver."""
from __future__ import annotations

import argparse
import importlib.util
from pathlib import Path
import runpy
import socket
import sys
import threading
import time
import urllib.request
import webbrowser

SOFTWARE = Path(__file__).resolve().parents[1]
SERVER = SOFTWARE.parent / 'hardware' / 'Ti60_MJPEG_Adaptive1080p720p_LightUI_20261022' / 'source' / 'net_web'
UI = SOFTWARE / 'pc_client' / 'cyberpunk_ui'


def check_port(kind: int, address: str, port: int) -> str | None:
    try:
        with socket.socket(socket.AF_INET, kind) as sock:
            if sys.platform == 'win32':
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            sock.bind((address, port))
    except OSError as exc:
        return str(exc)
    return None


def open_when_ready(url: str) -> None:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(url + '/api/status', timeout=1) as response:
                if response.status == 200:
                    webbrowser.open(url)
                    return
        except OSError:
            time.sleep(.2)


def main() -> int:
    if sys.platform == 'win32':
        try:
            # The Wi-Fi/UDP path needs timely scheduling even when the desktop
            # is busy compiling; without this the receiver can fall to 1 fps
            # while the browser decodes the same MJPEG stream.
            import ctypes
            k = ctypes.windll.kernel32
            k.GetCurrentProcess.restype = ctypes.c_void_p
            k.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_uint]
            k.SetPriorityClass.restype = ctypes.c_int
            k.SetPriorityClass(k.GetCurrentProcess(), 0x00000080)  # HIGH_PRIORITY_CLASS
        except Exception:
            pass
    parser = argparse.ArgumentParser(description='易灵绘 PC 无线视频与远程控制（复用 net_web）')
    parser.add_argument('--board', default='192.168.0.2', help='板2 IP')
    parser.add_argument('--http-port', type=int, default=8080, help='浏览器端口')
    parser.add_argument('--video-port', type=int, default=5001, help='UDP 视频端口，须与板2匹配')
    parser.add_argument('--ctrl-port', type=int, default=5000, help='UDP 控制端口，须与板2固定回包端口匹配')
    parser.add_argument('--bind', default='0.0.0.0', help='本机绑定地址')
    parser.add_argument('--no-browser', action='store_true', help='只启动服务，不自动打开浏览器')
    parser.add_argument('--check', action='store_true', help='只检查本机文件、依赖和端口，不访问板子')
    args = parser.parse_args()
    for value in (args.http_port, args.video_port, args.ctrl_port):
        if not 1 <= value <= 65535:
            parser.error('端口须在 1..65535 内')
    if args.video_port == args.ctrl_port:
        parser.error('视频与控制 UDP 端口不能相同')
    for relative in ('streamd.py', 'netproto.py', 'reclog.py', 'live_agent.py',
                     'static/index.html', 'static/app.js', 'static/style.css'):
        if not (SERVER / relative).is_file():
            print(f'缺少接收程序文件：{SERVER / relative}', file=sys.stderr)
            return 2
    for relative in ('index.html', 'style.css', 'fonts/plexmono-400.woff2',
                     'fonts/plexmono-600.woff2', 'fonts/plexsans-600.woff2'):
        if not (UI / relative).is_file():
            print(f'缺少赛博朋克网页资源：{UI / relative}', file=sys.stderr)
            return 2
    missing = [name for name in ('numpy', 'PIL') if importlib.util.find_spec(name) is None]
    if missing:
        print('缺少依赖：' + ', '.join(missing), file=sys.stderr)
        print(f'请使用项目 Python 安装："{sys.executable}" -m pip install numpy pillow', file=sys.stderr)
        return 2
    failed = False
    for label, kind, port in (('视频 UDP', socket.SOCK_DGRAM, args.video_port),
                              ('控制 UDP', socket.SOCK_DGRAM, args.ctrl_port),
                              ('网页 TCP', socket.SOCK_STREAM, args.http_port)):
        error = check_port(kind, args.bind, port)
        if error:
            failed = True
            print(f'{label} {port} 无法绑定：{error}', file=sys.stderr)
    if failed:
        print('请先释放被占用端口。本程序不会终止其他应用，也不会修改网卡或防火墙。', file=sys.stderr)
        print('板2控制回包固定发往5000；只改电脑端口不能解决该端口冲突。', file=sys.stderr)
        return 2
    url = f'http://127.0.0.1:{args.http_port}'
    print('易灵绘 PC 接收端：JPEG 原样透传，不在电脑上二次编码。', flush=True)
    print(f'板2 {args.board} | 视频 UDP {args.video_port} | 控制 UDP {args.ctrl_port}', flush=True)
    print(f'网页：{url}/', flush=True)
    if args.check:
        print('本机检查通过；尚未验证无线链路或收到板上视频。')
        return 0
    if not args.no_browser:
        threading.Thread(target=open_when_ready, args=(url,), daemon=True).start()
    # -I intentionally removes implicit local imports; add only this known source folder.
    sys.path.insert(0, str(SERVER))
    sys.argv = [str(SERVER / 'streamd.py'), '--board', args.board,
                '--w', '1280', '--h', '720', '--mjpeg-input',
                '--video-port', str(args.video_port), '--ctrl-port', str(args.ctrl_port),
                '--http-port', str(args.http_port), '--bind', args.bind]
    runpy.run_path(str(SERVER / 'streamd.py'), run_name='__main__')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
