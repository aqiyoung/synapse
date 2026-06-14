#!/usr/bin/env python3
"""生成 Synapse 液态玻璃 v2 图标（按 SensenNova 评估优化）

v2 改进：
- 神经突触节点改为半透明玻璃（边缘可透出底色）
- 连线从节点内部"生长"出来（不是搭表面），中心高亮 + 外发光 = 神经脉冲
- 节点高光加冷色淡蓝（与暖色背景形成冷暖对比）
- 球体加次表面散射感（边缘羽化）
- 整体保持径向渐变 + 顶部玻璃高光
"""
import os
import math
from PIL import Image, ImageDraw, ImageFilter, ImageChops

# 暖色系
COLOR_BG_TOP = (201, 100, 66)
COLOR_BG_BOT = (138, 58, 32)
COLOR_NODE = (255, 248, 240)      # 浅米色
COLOR_NODE_RIM = (138, 58, 32)
COLOR_LINE = (255, 255, 255)

SIZES = {
    'mdpi': 48, 'hdpi': 72, 'xhdpi': 96,
    'xxhdpi': 144, 'xxxhdpi': 192,
}
BASE_SIZE = 432  # 4x 超采样


def radial_bg(size):
    """径向渐变背景：中心偏上亮，边缘深"""
    img = Image.new('RGB', (size, size), COLOR_BG_BOT)
    pixels = img.load()
    cx, cy = size * 0.5, size * 0.32
    max_dist = math.hypot(size, size) / 2
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - cx, y - cy) / max_dist
            d = min(1.0, d)
            t = d ** 1.3  # 让中心更亮
            r = int(COLOR_BG_TOP[0] * (1 - t) + COLOR_BG_BOT[0] * t)
            g = int(COLOR_BG_TOP[1] * (1 - t) + COLOR_BG_BOT[1] * t)
            b = int(COLOR_BG_TOP[2] * (1 - t) + COLOR_BG_BOT[2] * t)
            pixels[x, y] = (r, g, b)
    return img


def glass_highlight(size):
    """顶部 30% 区域的玻璃高光"""
    hl = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(hl)
    for i in range(30, 0, -1):
        alpha = int(255 * (i / 30) * 0.22)
        inset = (size * 0.5) * (1 - i / 30) * 0.4
        box = (
            int(-size * 0.3 + inset),
            int(-size * 0.5 + inset * 0.6),
            int(size * 1.3 - inset),
            int(size * 0.55 - inset * 0.4),
        )
        draw.ellipse(box, fill=(255, 255, 255, alpha))
    hl = hl.filter(ImageFilter.GaussianBlur(radius=size * 0.04))
    return hl


def draw_neural_pulse(canvas, x1, y1, x2, y2, w):
    """v3 神经突触连线：去几何化、边缘模糊、节点处融合"""
    # 1. 外发光（暖色光晕，模拟神经冲动）
    glow = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.line([(x1, y1), (x2, y2)], fill=(255, 195, 145, 70), width=int(w * 4))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=w * 2.2))
    canvas.alpha_composite(glow)

    # 2. 主线（白色半透明） + 边缘高斯模糊（去几何化）
    main = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    md = ImageDraw.Draw(main)
    md.line([(x1, y1), (x2, y2)], fill=(255, 250, 240, 160), width=int(w * 0.7))
    main = main.filter(ImageFilter.GaussianBlur(radius=w * 0.25))
    canvas.alpha_composite(main)

    # 3. 中心高亮（冷色淡蓝，神经信号 + 冷暖对比）
    core = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    cd = ImageDraw.Draw(core)
    cd.line([(x1, y1), (x2, y2)], fill=(230, 245, 255, 220), width=int(w * 0.25))
    core = core.filter(ImageFilter.GaussianBlur(radius=w * 0.4))
    canvas.alpha_composite(core)

    # 4. 节点附近淡出（v3：连线在节点处渐变溶解进球体）
    # 从节点中心向外画一个淡出晕
    for (px, py) in [(x1, y1), (x2, y2)]:
        fade = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
        fd = ImageDraw.Draw(fade)
        # 画一个比节点稍大的半透明圆（颜色同背景），覆盖连线末端
        # 先用一个白色圆，alpha 从中心到边缘递减
        for r_off in range(int(w * 6), 0, -1):
            t = r_off / (w * 6)
            alpha = int(180 * (1 - t))
            fd.ellipse(
                [px - r_off, py - r_off, px + r_off, py + r_off],
                fill=(180, 80, 50, alpha)
            )
        fade = fade.filter(ImageFilter.GaussianBlur(radius=w * 0.8))
        canvas.alpha_composite(fade)


def draw_glass_node(canvas, cx, cy, r):
    """v2 玻璃节点：
    - 半透明球体（边缘可透出底色）
    - 内部径向渐变（中心亮米色 → 边缘深红）
    - 顶部冷色高光（淡蓝，制造冷暖对比）
    - 外环描边（深红）
    - 下方投影
    """
    # 1. 下方投影
    shadow = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    sd.ellipse(
        [cx - r * 0.95, cy - r * 0.85 + r * 0.18,
         cx + r * 0.95, cy + r * 0.85 + r * 0.18],
        fill=(0, 0, 0, 100)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=r * 0.18))
    canvas.alpha_composite(shadow)

    # 2. 外环（深红描边，制造玻璃厚度感）
    ring = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse(
        [cx - r, cy - r, cx + r, cy + r],
        fill=(80, 30, 18, 220)  # 深红描边
    )
    canvas.alpha_composite(ring)

    # 3. 内部球体（半透明 + 径向渐变）
    ball_size = int(r * 1.85)
    ball = Image.new('RGBA', (ball_size, ball_size), (0, 0, 0, 0))
    bcx, bcy = ball_size // 2, ball_size // 2
    for y in range(ball_size):
        for x in range(ball_size):
            d = math.hypot(x - bcx, y - bcy) / r
            if d > 0.95:
                continue
            # 主体颜色
            t = d ** 1.4
            rr = int(255 * (1 - t * 0.5) + 240 * t * 0.5)
            gg = int(248 * (1 - t * 0.4) + 200 * t * 0.4)
            bb = int(235 * (1 - t * 0.4) + 170 * t * 0.4)
            # 顶部冷色高光（上方 1/3）
            if y < bcy:
                coolness = max(0, (bcy - y) / r) * 0.6
                rr = max(0, int(rr - 20 * coolness))
                gg = min(255, int(gg + 10 * coolness))
                bb = min(255, int(bb + 30 * coolness))
            # 整体 alpha（边缘渐透）
            alpha = int(255 * (1 - max(0, (d - 0.7) / 0.25)) if d > 0.7 else 255)
            ball.putpixel((x, y), (rr, gg, bb, alpha))
    canvas.alpha_composite(ball, dest=(int(cx - bcx), int(cy - bcy)))

    # 4. 顶部小高光（亮白小弧）
    hl = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    hd = ImageDraw.Draw(hl)
    hd.ellipse(
        [cx - r * 0.6, cy - r * 0.95, cx + r * 0.3, cy - r * 0.45],
        fill=(255, 255, 255, 200)
    )
    hl = hl.filter(ImageFilter.GaussianBlur(radius=r * 0.08))
    canvas.alpha_composite(hl)

    # 5. 底部反光（很弱的暖色，模拟次表面散射）
    bottom = Image.new('RGBA', canvas.size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(bottom)
    bd.ellipse(
        [cx - r * 0.7, cy + r * 0.3, cx + r * 0.7, cy + r * 0.85],
        fill=(255, 180, 130, 70)
    )
    bottom = bottom.filter(ImageFilter.GaussianBlur(radius=r * 0.12))
    canvas.alpha_composite(bottom)


def compose_icon(size):
    bg = radial_bg(size).convert('RGBA')
    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(bg)
    canvas.alpha_composite(glass_highlight(size))

    # 三角布局的 3 节点
    cx, cy = size * 0.5, size * 0.55
    r = size * 0.135
    nodes = [
        (cx - size * 0.21, cy - size * 0.13),
        (cx + size * 0.21, cy - size * 0.13),
        (cx, cy + size * 0.22),
    ]
    # 连线（在节点之前画，让节点"压"在线上方）
    w = size * 0.022
    for i in range(3):
        a, b = nodes[i], nodes[(i + 1) % 3]
        draw_neural_pulse(canvas, a[0], a[1], b[0], b[1], w)
    for n in nodes:
        draw_glass_node(canvas, n[0], n[1], r)

    return canvas


def main():
    out_dir = '/vol1/1000/dev-projects/synapse/app/assets/icons'
    os.makedirs(out_dir, exist_ok=True)

    for name, size in SIZES.items():
        big = compose_icon(BASE_SIZE)
        img = big.resize((size, size), Image.LANCZOS)
        asset_path = f'{out_dir}/icon_{name}_v2.png'
        img.save(asset_path, 'PNG', optimize=True)
        mipmap_path = f'/vol1/1000/dev-projects/synapse/app/android/app/src/main/res/mipmap-{name}/ic_launcher.png'
        os.makedirs(os.path.dirname(mipmap_path), exist_ok=True)
        img.save(mipmap_path, 'PNG', optimize=True)
        print(f'  ✅ {name} {size}px -> {mipmap_path}')

    # round launcher（圆形）
    for name, size in SIZES.items():
        big = compose_icon(BASE_SIZE)
        mask = Image.new('L', (BASE_SIZE, BASE_SIZE), 0)
        ImageDraw.Draw(mask).ellipse([0, 0, BASE_SIZE, BASE_SIZE], fill=255)
        bg_layer = Image.new('RGBA', (BASE_SIZE, BASE_SIZE), (0, 0, 0, 0))
        bg_layer.paste(big, (0, 0), big)
        out = Image.new('RGBA', (BASE_SIZE, BASE_SIZE), (0, 0, 0, 0))
        out.paste(bg_layer, (0, 0), mask)
        out = out.resize((size, size), Image.LANCZOS)
        out.save(
            f'/vol1/1000/dev-projects/synapse/app/android/app/src/main/res/mipmap-{name}/ic_launcher_round.png',
            'PNG', optimize=True
        )

    print('\n✅ v3 图标全部生成')


if __name__ == '__main__':
    main()
