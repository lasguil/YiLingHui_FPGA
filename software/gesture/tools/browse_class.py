"""随机浏览某个类的图片（幻灯片式，默认 10 张/秒）。

用法：
    python browse_class.py --class 手掌                # 随机顺序，10 张/秒
    python browse_class.py --class 手背 --fps 5        # 慢一点
    python browse_class.py --class 手掌 --no-shuffle --start 500
快捷键：空格=暂停/继续   →或n=下一张   ←或p=上一张   r=重新打乱   q或Esc=退出
"""
import argparse
import os
import random
import sys
import tkinter as tk
from tkinter import font as tkfont

from PIL import Image, ImageTk

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, '..', 'dataset')
EXTS = ('.jpeg', '.jpg', '.png', '.bmp', '.webp')


def collect(class_name):
    root = os.path.join(DATA, class_name)
    if not os.path.isdir(root):
        sys.exit(f'找不到目录: {root}')
    files = []
    for dirpath, _, names in os.walk(root):
        for n in sorted(names):
            if n.lower().endswith(EXTS):
                files.append(os.path.join(dirpath, n))
    return files


class Browser:
    def __init__(self, root, files, fps, start, fit):
        self.root = root
        self.files = files
        self.interval = int(1000 / fps)
        self.index = max(0, min(start, len(files) - 1))
        self.paused = False
        self.after_id = None

        root.title(f'浏览 {len(files)} 张   (空格暂停 / ←→ 单步 / q 退出)')
        root.configure(bg='#111111')
        self.screen_w = root.winfo_screenwidth() - 120
        self.screen_h = root.winfo_screenheight() - 160
        self.fit = fit
        self.label = tk.Label(root, bg='#111111', bd=0)
        self.label.pack(expand=True)
        self.info = tk.Label(root, bg='#111111', fg='#88ff88',
                             font=tkfont.Font(family='Microsoft YaHei UI', size=11))
        self.info.pack(fill='x')
        root.bind('<space>', self.toggle)
        root.bind('<Right>', lambda e: self.step(1))
        root.bind('<n>', lambda e: self.step(1))
        root.bind('<Left>', lambda e: self.step(-1))
        root.bind('<p>', lambda e: self.step(-1))
        root.bind('<r>', lambda e: self.shuffle())
        root.bind('<q>', lambda e: root.destroy())
        root.bind('<Escape>', lambda e: root.destroy())
        self.tk_img = None
        self.show()
        self.schedule()

    def shuffle(self):
        random.shuffle(self.files)
        self.index = 0
        print('已重新打乱', flush=True)

    def load_image(self, path):
        im = Image.open(path).convert('RGB')
        if self.fit:
            im.thumbnail((self.screen_w, self.screen_h), Image.LANCZOS)
        return ImageTk.PhotoImage(im)

    def show(self):
        path = self.files[self.index]
        try:
            self.tk_img = self.load_image(path)
        except Exception as exc:                     # 坏图不中断浏览
            print(f'跳过损坏文件 {path}: {exc}', flush=True)
            self.index = (self.index + 1) % len(self.files)
            return self.show()
        self.label.configure(image=self.tk_img)
        sub = os.path.basename(os.path.dirname(path))
        self.info.configure(text=f'[{self.index + 1}/{len(self.files)}]  {sub}/  '
                                 f'{os.path.basename(path)}   '
                                 f'{"已暂停" if self.paused else "播放中"}')
        if self.index % 100 == 0:
            print(f'  {self.index + 1}/{len(self.files)}', flush=True)

    def step(self, d):
        self.index = (self.index + d) % len(self.files)
        self.show()

    def toggle(self, _event=None):
        self.paused = not self.paused
        if self.paused and self.after_id:
            self.root.after_cancel(self.after_id)
            self.after_id = None
        elif not self.paused:
            self.schedule()
        self.show()

    def schedule(self):
        if not self.paused:
            self.after_id = self.root.after(self.interval, self.tick)

    def tick(self):
        self.after_id = None
        if self.paused:
            return
        self.index = (self.index + 1) % len(self.files)
        self.show()
        self.schedule()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--class', dest='cls', default='手掌', help='dataset/ 下的类名（手掌/手背/握拳/其它）')
    ap.add_argument('--fps', type=float, default=10.0, help='每秒张数（默认 10）')
    ap.add_argument('--start', type=int, default=0)
    ap.add_argument('--no-shuffle', action='store_true', help='不打乱，按文件名顺序')
    ap.add_argument('--no-fit', action='store_true', help='不缩放到屏幕，按原尺寸显示')
    args = ap.parse_args()

    files = collect(args.cls)
    if not files:
        sys.exit('该目录下没有图片')
    if not args.no_shuffle:
        random.shuffle(files)
    print(f'{args.cls}: {len(files)} 张，{args.fps:g} 张/秒，'
          f'{"随机顺序" if not args.no_shuffle else "文件名顺序"}'
          f'（全部看完约 {len(files) / args.fps / 60:.0f} 分钟）', flush=True)

    root = tk.Tk()
    Browser(root, files, args.fps, args.start, fit=not args.no_fit)
    root.mainloop()
    print('已退出', flush=True)


if __name__ == '__main__':
    main()
