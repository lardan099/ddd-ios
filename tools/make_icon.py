"""Рисует иконку приложения: LampaPlayer/Assets.xcassets/AppIcon.appiconset/icon-1024.png"""
import math
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

S = 2048  # рисуем с запасом и уменьшаем — сглаживание
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "LampaPlayer/Assets.xcassets/AppIcon.appiconset/icon-1024.png")


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


# Фон: радиальный градиент из тёмно-синего в почти чёрный.
bg = Image.new("RGB", (S, S))
px = bg.load()
center = (S * 0.5, S * 0.42)
max_r = math.hypot(S * 0.5, S * 0.58)
inner, outer = (38, 44, 92), (8, 9, 20)
for y in range(S):
    for x in range(S):
        t = min(math.hypot(x - center[0], y - center[1]) / max_r, 1)
        px[x, y] = lerp(inner, outer, t ** 0.9)

# Мягкое свечение за треугольником.
glow = Image.new("L", (S, S), 0)
ImageDraw.Draw(glow).ellipse([S * 0.24, S * 0.22, S * 0.80, S * 0.78], fill=150)
glow = glow.filter(ImageFilter.GaussianBlur(S * 0.09))
glow_color = Image.new("RGB", (S, S), (255, 96, 80))
bg = Image.composite(glow_color, bg, glow.point(lambda v: int(v * 0.55)))

# Треугольник «play» со скруглёнными углами: маска = многоугольник, расширенный кругами в вершинах.
cx, cy, size = S * 0.535, S * 0.5, S * 0.50
pts = [
    (cx - size * 0.42, cy - size * 0.5),
    (cx - size * 0.42, cy + size * 0.5),
    (cx + size * 0.5, cy),
]
r = S * 0.055
mask = Image.new("L", (S, S), 0)
d = ImageDraw.Draw(mask)
# Сжимаем вершины к центру на r и рисуем толстый контур — получаем скругление.
gx = sum(p[0] for p in pts) / 3
gy = sum(p[1] for p in pts) / 3
shrunk = []
for x, y in pts:
    dx, dy = gx - x, gy - y
    k = r * 2.0 / math.hypot(dx, dy)
    shrunk.append((x + dx * k, y + dy * k))
d.polygon(shrunk, fill=255)
d.line(shrunk + [shrunk[0]], fill=255, width=int(r * 2), joint="curve")
for x, y in shrunk:
    d.ellipse([x - r, y - r, x + r, y + r], fill=255)

# Заливка треугольника: тёплый градиент сверху вниз.
grad = Image.new("RGB", (S, S))
gp = grad.load()
top, bottom = (255, 168, 76), (255, 58, 120)
for y in range(S):
    c = lerp(top, bottom, y / S)
    for x in range(S):
        gp[x, y] = c

# Тень под треугольником.
shadow = mask.filter(ImageFilter.GaussianBlur(S * 0.02)).point(lambda v: int(v * 0.45))
shadow = shadow.transform(shadow.size, Image.AFFINE, (1, 0, 0, 0, 1, -S * 0.012))
bg = Image.composite(Image.new("RGB", (S, S), (0, 0, 0)), bg, shadow)
bg = Image.composite(grad, bg, mask)

icon = bg.resize((1024, 1024), Image.LANCZOS)
OUT.parent.mkdir(parents=True, exist_ok=True)
icon.save(OUT, "PNG")
print("saved", OUT, icon.size, icon.mode)
